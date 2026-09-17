import QtQuick
import QtQuick.Controls
import QtCore

import org.qfield
import org.qfield.core
import org.qgis
import Theme

Item {
  id: plugin
  objectName: "qfieldPnuViewer"

  property var mainWindow: iface.mainWindow()
  property var mapCanvas: iface.mapCanvas()
  property var pointHandler: null
  property bool handlerRegistered: false
  property bool pickMode: false

  property string parcelLayerExactName: "LSMD_CONT_LDREG - pnu 결합"
  property string currentPnu: ""
  property string currentLayerName: ""
  property string resultMode: "idle"
  property string statusText: "조회할 정보를 선택하세요."
  property string landBasicText: ""
  property string landZoneText: ""
  property string buildingText: ""

  Settings {
    id: settings
    category: "qfield-pnu-viewer"
    property string vworldKey: ""
    property string buildingKey: ""
  }

  function configure() { settingsDialog.open() }

  function registerPointHandler() {
    if (handlerRegistered)
      return true

    pointHandler = iface.findItemByObjectName("pointHandler")
    if (!pointHandler || !pointHandler.registerHandler) {
      retryTimer.restart()
      return false
    }

    var ok = pointHandler.registerHandler("qfield_pnu_viewer", function(point, type, interactionType) {
      if (!plugin.pickMode || interactionType !== "clicked")
        return false
      plugin.handleMapClick(point)
      return true
    })

    handlerRegistered = ok !== false
    return handlerRegistered
  }

  Timer {
    id: retryTimer
    interval: 700
    repeat: false
    onTriggered: plugin.registerPointHandler()
  }

  Connections {
    target: iface
    function onLoadProjectEnded() { retryTimer.restart() }
  }

  Component.onCompleted: {
    iface.addItemToPluginsToolbar(toolButton)
    retryTimer.start()
  }

  Component.onDestruction: {
    try {
      if (pointHandler && handlerRegistered && pointHandler.deregisterHandler)
        pointHandler.deregisterHandler("qfield_pnu_viewer")
    } catch (e) {}
  }

  function normalizePnu(value) {
    var s = String(value === undefined || value === null ? "" : value).trim()
    if (s.endsWith(".0"))
      s = s.slice(0, -2)
    s = s.replace(/[^0-9]/g, "")
    return s.length === 19 ? s : ""
  }

  function featurePnu(feature) {
    var names = ["PNU", "pnu", "Pnu", "필지고유번호", "PIN", "pin", "PNU19", "PNU_CD", "PNU_CODE"]
    for (var i = 0; i < names.length; i++) {
      try {
        var p = normalizePnu(feature.attribute(names[i]))
        if (p)
          return p
      } catch (e) {}
    }
    return ""
  }

  function findParcelLayer() {
    var exact = qgisProject.mapLayersByName(parcelLayerExactName)
    if (exact && exact.length > 0)
      return exact[0]

    var layers = QfProjectUtils.mapLayers(qgisProject)
    var fallback = null
    for (var layerId in layers) {
      var layer = layers[layerId]
      if (!layer)
        continue
      var n = String(layer.name || "")
      var low = n.toLowerCase()
      if (low.indexOf("lsmd_cont_ldreg") >= 0 && low.indexOf("pnu") >= 0)
        return layer
      if (!fallback && low.indexOf("lsmd_cont_ldreg") >= 0)
        fallback = layer
    }
    return fallback
  }

  function startPick() {
    if (!registerPointHandler()) {
      mainWindow.displayToast("지도 선택 기능을 준비 중입니다. 1초 뒤 다시 눌러주세요.")
      return
    }

    var layer = findParcelLayer()
    if (!layer) {
      mainWindow.displayToast("'" + parcelLayerExactName + "' 레이어를 찾지 못했습니다.")
      return
    }

    pickMode = true
    mainWindow.displayToast("필지를 한 번 탭하세요 · " + layer.name)
  }

  function handleMapClick(point) {
    pickMode = false
    var layer = findParcelLayer()

    if (!layer) {
      mainWindow.displayToast("'" + parcelLayerExactName + "' 레이어를 찾지 못했습니다.")
      return
    }

    try {
      var tlCanvas = mapCanvas.mapSettings.screenToCoordinate(Qt.point(point.x - 6, point.y - 6))
      var brCanvas = mapCanvas.mapSettings.screenToCoordinate(Qt.point(point.x + 6, point.y + 6))
      var canvasRect = QfGeometryUtils.createRectangleFromPoints(tlCanvas, brCanvas)
      var sourceCrs = mapCanvas.mapSettings.destinationCrs
      var layerRect = QfGeometryUtils.reprojectRectangle(canvasRect, sourceCrs, layer.crs)
      var it = QfLayerUtils.createFeatureIteratorFromRectangle(layer, layerRect)

      while (it.hasNext()) {
        var f = it.next()
        var p = featurePnu(f)
        if (p) {
          currentPnu = p
          currentLayerName = layer.name
          resultMode = "idle"
          statusText = "조회할 정보를 선택하세요."
          landBasicText = ""
          landZoneText = ""
          buildingText = ""
          mainWindow.displayToast("PNU 확인: " + p)
          resultDialog.open()
          return
        }
      }

      mainWindow.displayToast("탭한 위치에서 필지를 찾지 못했습니다.")
    } catch (e) {
      console.log("qfield-pnu-viewer selection error: " + e)
      mainWindow.displayToast("필지 선택 오류: " + e)
    }
  }

  function cleanKey(value) {
    var s = String(value || "").trim()
    if (s.indexOf("%") >= 0) {
      try { s = decodeURIComponent(s) } catch (e) {}
    }
    return s
  }

  function getJson(url, success, failure) {
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE)
        return
      if (xhr.status >= 200 && xhr.status < 300) {
        try { success(JSON.parse(xhr.responseText)) }
        catch (e) { failure("JSON 응답 해석 실패") }
      } else {
        failure("HTTP " + xhr.status)
      }
    }
    xhr.onerror = function() { failure("네트워크 연결 실패") }
    xhr.open("GET", url)
    xhr.setRequestHeader("Accept", "application/json")
    xhr.send()
  }

  function walk(node, callback) {
    if (node === null || node === undefined)
      return
    if (Array.isArray(node)) {
      for (var i = 0; i < node.length; i++)
        walk(node[i], callback)
      return
    }
    if (typeof node === "object") {
      callback(node)
      for (var k in node)
        walk(node[k], callback)
    }
  }

  function first(obj, names) {
    for (var i = 0; i < names.length; i++) {
      var v = obj[names[i]]
      if (v !== undefined && v !== null && String(v).trim() !== "")
        return String(v).trim()
    }
    return ""
  }

  function findParcelObject(data) {
    var found = null
    walk(data, function(o) {
      if (found)
        return
      if (o.lndpclAr !== undefined || o.lndcgrCodeNm !== undefined || o.lndcgrCode !== undefined)
        found = o
    })
    return found
  }

  function formatArea(value) {
    var s = String(value === undefined || value === null ? "" : value).trim()
    if (!s)
      return "-"
    var n = Number(s)
    if (isNaN(n))
      return s + " ㎡"
    var rounded = Math.round(n * 100) / 100
    return String(rounded).replace(/\B(?=(\d{3})+(?!\d))/g, ",") + " ㎡"
  }

  function zoneTextFromData(data) {
    var seen = {}
    var lines = []
    walk(data, function(o) {
      var name = first(o, ["prposAreaDstrcCodeNm", "prposAreaDstrcCode"])
      if (name && !seen[name]) {
        seen[name] = true
        lines.push("• " + name)
      }
    })
    return lines.length ? lines.join("\n") : "조회된 지역·지구 지정내역이 없습니다."
  }

  function renderLand(parcel, zoneData, parcelError, zoneError) {
    var basic = []
    if (parcel) {
      var dong = first(parcel, ["ldCodeNm"])
      var lot = first(parcel, ["mnnmSlno"])
      var address = dong
      if (lot)
        address = address ? address + " " + lot : lot

      basic.push("소재지  " + (address || "-"))
      basic.push("지번  " + (lot || "-"))
      basic.push("지목  " + (first(parcel, ["lndcgrCodeNm", "lndcgrCode"]) || "-"))
      basic.push("지적면적  " + formatArea(first(parcel, ["lndpclAr"])))
      basic.push("대장구분  " + (first(parcel, ["regstrSeCodeNm", "regstrSeCode"]) || "-"))
    } else {
      basic.push("토지 기본정보를 불러오지 못했습니다.")
      if (parcelError)
        basic.push(parcelError)
    }

    landBasicText = basic.join("\n")
    landZoneText = zoneData ? zoneTextFromData(zoneData) :
                   (zoneError ? "지정내역 조회 실패 · " + zoneError : "조회된 지역·지구 지정내역이 없습니다.")
    resultMode = "land"
    statusText = parcel || zoneData ? "토지정보 조회 완료" : "조회에 실패했습니다."
  }

  function queryLand() {
    if (!settings.vworldKey.trim()) {
      mainWindow.displayToast("플러그인 설정에서 브이월드 API 키를 입력하세요.")
      settingsDialog.open()
      return
    }

    resultMode = "land"
    statusText = "토지정보를 조회하고 있습니다…"
    landBasicText = "조회 중…"
    landZoneText = "조회 중…"

    var key = encodeURIComponent(settings.vworldKey.trim())
    var pnu = encodeURIComponent(currentPnu)
    var parcelUrl = "https://api.vworld.kr/ned/data/ladfrlList?format=json&key=" + key + "&pnu=" + pnu
    var zoneUrl = "https://api.vworld.kr/ned/data/getLandUseAttr?format=json&key=" + key + "&pnu=" + pnu + "&numOfRows=1000&pageNo=1"

    getJson(parcelUrl, function(parcelData) {
      var parcel = findParcelObject(parcelData)
      getJson(zoneUrl, function(zoneData) {
        renderLand(parcel, zoneData, "", "")
      }, function(zoneErr) {
        renderLand(parcel, null, "", zoneErr)
      })
    }, function(parcelErr) {
      getJson(zoneUrl, function(zoneData) {
        renderLand(null, zoneData, parcelErr, "")
      }, function(zoneErr) {
        renderLand(null, null, parcelErr, zoneErr)
      })
    })
  }

  function buildingParams() {
    var p = normalizePnu(currentPnu)
    if (!p)
      return null
    return {
      sigungu: p.slice(0, 5),
      bjdong: p.slice(5, 10),
      plat: p.charAt(10) === "2" ? "1" : "0",
      bun: p.slice(11, 15),
      ji: p.slice(15, 19)
    }
  }

  function queryBuilding() {
    if (!settings.buildingKey.trim()) {
      mainWindow.displayToast("플러그인 설정에서 건축HUB API 키를 입력하세요.")
      settingsDialog.open()
      return
    }

    var p = buildingParams()
    if (!p)
      return

    resultMode = "building"
    statusText = "건축물대장을 조회하고 있습니다…"
    buildingText = "조회 중…"

    var url = "https://apis.data.go.kr/1613000/BldRgstHubService/getBrTitleInfo" +
      "?serviceKey=" + encodeURIComponent(cleanKey(settings.buildingKey)) +
      "&sigunguCd=" + p.sigungu +
      "&bjdongCd=" + p.bjdong +
      "&platGbCd=" + p.plat +
      "&bun=" + p.bun +
      "&ji=" + p.ji +
      "&numOfRows=100&pageNo=1&_type=json"

    getJson(url, function(data) {
      var rows = []
      var seen = {}
      walk(data, function(o) {
        if (o.mgmBldrgstPk !== undefined || o.platPlc !== undefined) {
          var id = first(o, ["mgmBldrgstPk"]) || JSON.stringify(o)
          if (!seen[id]) {
            seen[id] = true
            rows.push(o)
          }
        }
      })

      if (!rows.length) {
        buildingText = "건축물대장 표제부를 찾지 못했습니다."
        statusText = "조회 결과 없음"
        return
      }

      var blocks = []
      for (var i = 0; i < rows.length; i++) {
        var r = rows[i]
        blocks.push(
          (first(r, ["bldNm", "dongNm"]) || "건축물") +
          "\n소재지  " + (first(r, ["platPlc", "newPlatPlc"]) || "-") +
          "\n주용도  " + (first(r, ["mainPurpsCdNm", "etcPurps"]) || "-") +
          "\n구조  " + (first(r, ["strctCdNm", "etcStrct"]) || "-") +
          "\n건축면적  " + (first(r, ["archArea"]) || "-") + " ㎡" +
          "\n연면적  " + (first(r, ["totArea"]) || "-") + " ㎡" +
          "\n건폐율  " + (first(r, ["bcRat"]) || "-") + "%" +
          "\n용적률  " + (first(r, ["vlRat"]) || "-") + "%" +
          "\n지상/지하  " + (first(r, ["grndFlrCnt"]) || "-") + " / " + (first(r, ["ugrndFlrCnt"]) || "-") +
          "\n사용승인일  " + (first(r, ["useAprDay"]) || "-")
        )
      }

      buildingText = blocks.join("\n\n────────────\n\n")
      statusText = "건축물대장 조회 완료"
    }, function(err) {
      buildingText = "건축물대장 조회 실패\n" + err
      statusText = "조회에 실패했습니다."
    })
  }

  QfToolButton {
    id: toolButton
    iconSource: "icon.svg"
    iconColor: "white"
    bgcolor: pickMode ? Theme.mainColor : Theme.darkGray
    round: true
    onClicked: plugin.startPick()
  }

  Dialog {
    id: settingsDialog
    parent: mainWindow.contentItem
    modal: true
    title: "PNU Viewer 설정"
    width: Math.min(mainWindow.width * 0.9, 700)
    height: Math.min(mainWindow.height * 0.65, 500)
    x: (mainWindow.width - width) / 2
    y: (mainWindow.height - height) / 2
    standardButtons: Dialog.Ok | Dialog.Cancel

    onOpened: {
      vworldField.text = settings.vworldKey
      buildingField.text = settings.buildingKey
    }
    onAccepted: {
      settings.vworldKey = vworldField.text.trim()
      settings.buildingKey = buildingField.text.trim()
      mainWindow.displayToast("API 키를 저장했습니다.")
    }

    Column {
      width: parent.width
      spacing: 10
      Label { text: "브이월드 API 키"; font.bold: true }
      TextField {
        id: vworldField
        width: parent.width
        echoMode: TextInput.Password
        placeholderText: "VWorld NED API 인증키"
      }
      Label { text: "건축HUB API 키"; font.bold: true }
      TextField {
        id: buildingField
        width: parent.width
        echoMode: TextInput.Password
        placeholderText: "공공데이터포털 일반 인증키"
      }
    }
  }

  Dialog {
    id: resultDialog
    parent: mainWindow.contentItem
    modal: true
    title: "필지 정보"
    width: Math.min(mainWindow.width * 0.94, 820)
    height: Math.min(mainWindow.height * 0.88, 860)
    x: (mainWindow.width - width) / 2
    y: (mainWindow.height - height) / 2
    standardButtons: Dialog.Close

    Column {
      width: parent.width
      height: parent.height
      spacing: 12

      Rectangle {
        width: parent.width
        height: headerColumn.implicitHeight + 28
        radius: 12
        color: "#F5F6F7"
        border.color: "#E2E4E7"

        Column {
          id: headerColumn
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: 14
          spacing: 4
          Label { text: "선택 필지"; font.pixelSize: 13; color: "#6B7280" }
          Label {
            width: parent.width
            text: currentPnu
            font.pixelSize: 20
            font.bold: true
            color: "#202124"
            wrapMode: Text.WordWrap
          }
          Label {
            width: parent.width
            text: currentLayerName
            font.pixelSize: 13
            color: "#6B7280"
            elide: Text.ElideRight
          }
        }
      }

      Row {
        width: parent.width
        spacing: 10
        Button {
          width: (parent.width - parent.spacing) / 2
          text: "토지이용계획"
          onClicked: plugin.queryLand()
        }
        Button {
          width: (parent.width - parent.spacing) / 2
          text: "건축물대장"
          onClicked: plugin.queryBuilding()
        }
      }

      Label {
        width: parent.width
        text: statusText
        font.pixelSize: 13
        color: "#6B7280"
        wrapMode: Text.WordWrap
      }

      Flickable {
        id: resultFlick
        width: parent.width
        height: parent.height - 170
        contentWidth: width
        contentHeight: cardsColumn.implicitHeight
        clip: true

        Column {
          id: cardsColumn
          width: resultFlick.width
          spacing: 12

          Rectangle {
            width: parent.width
            height: idleColumn.implicitHeight + 32
            radius: 12
            color: "#FFFFFF"
            border.color: "#E2E4E7"
            visible: resultMode === "idle"
            Column {
              id: idleColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: 16
              spacing: 8
              Label { text: "조회 항목을 선택하세요"; font.pixelSize: 17; font.bold: true; color: "#202124" }
              Label {
                width: parent.width
                text: "토지이용계획에서는 지번·지목·지적면적과 지역·지구 지정내역을 확인할 수 있습니다."
                wrapMode: Text.WordWrap
                color: "#5F6368"
              }
            }
          }

          Rectangle {
            width: parent.width
            height: basicColumn.implicitHeight + 32
            radius: 12
            color: "#FFFFFF"
            border.color: "#E2E4E7"
            visible: resultMode === "land"
            Column {
              id: basicColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: 16
              spacing: 10
              Label { text: "토지 기본정보"; font.pixelSize: 18; font.bold: true; color: "#202124" }
              Rectangle { width: parent.width; height: 1; color: "#ECEFF1" }
              Label {
                width: parent.width
                text: landBasicText
                font.pixelSize: 15
                lineHeight: 1.35
                wrapMode: Text.WordWrap
                color: "#303134"
              }
            }
          }

          Rectangle {
            width: parent.width
            height: zoneColumn.implicitHeight + 32
            radius: 12
            color: "#FFFFFF"
            border.color: "#E2E4E7"
            visible: resultMode === "land"
            Column {
              id: zoneColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: 16
              spacing: 10
              Label { text: "토지이용계획"; font.pixelSize: 18; font.bold: true; color: "#202124" }
              Rectangle { width: parent.width; height: 1; color: "#ECEFF1" }
              Label {
                width: parent.width
                text: landZoneText
                font.pixelSize: 15
                lineHeight: 1.35
                wrapMode: Text.WordWrap
                color: "#303134"
              }
            }
          }

          Rectangle {
            width: parent.width
            height: buildingColumn.implicitHeight + 32
            radius: 12
            color: "#FFFFFF"
            border.color: "#E2E4E7"
            visible: resultMode === "building"
            Column {
              id: buildingColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: 16
              spacing: 10
              Label { text: "건축물대장"; font.pixelSize: 18; font.bold: true; color: "#202124" }
              Rectangle { width: parent.width; height: 1; color: "#ECEFF1" }
              Label {
                width: parent.width
                text: buildingText
                font.pixelSize: 15
                lineHeight: 1.35
                wrapMode: Text.WordWrap
                color: "#303134"
              }
            }
          }
        }
      }
    }
  }
}
