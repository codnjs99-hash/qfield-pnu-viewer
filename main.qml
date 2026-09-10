import QtQuick
import QtQuick.Controls
import QtCore

import org.qfield
import org.qgis
import Theme

Item {
  id: plugin
  objectName: "qfieldPnuViewer"

  property var mainWindow: iface.mainWindow()
  property var mapCanvas: iface.mapCanvas()
  property var dashBoard: iface.findItemByObjectName("dashBoard")
  property var pointHandler: null
  property bool handlerRegistered: false
  property bool pickMode: false
  property string currentPnu: ""
  property string currentLayerName: ""
  property string resultText: "필지를 선택한 뒤 조회 버튼을 누르세요."

  Settings {
    id: settings
    category: "qfield-pnu-viewer"
    property string vworldKey: ""
    property string buildingKey: ""
  }

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
    if (handlerRegistered)
      console.log("qfield-pnu-viewer: map handler registered")
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
    function onLoadProjectEnded() {
      retryTimer.restart()
    }
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

  function configure() {
    settingsDialog.open()
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

  function startPick() {
    if (!registerPointHandler()) {
      mainWindow.displayToast("지도 선택 기능을 준비 중입니다. 1초 뒤 다시 눌러주세요.")
      return
    }

    var layer = dashBoard ? dashBoard.activeLayer : null
    if (!layer) {
      mainWindow.displayToast("먼저 PNU가 있는 연속지적도 레이어를 선택하세요.")
      return
    }

    pickMode = true
    mainWindow.displayToast("필지를 한 번 탭하세요 · " + layer.name)
  }

  function handleMapClick(point) {
    var layer = dashBoard ? dashBoard.activeLayer : null
    pickMode = false

    if (!layer) {
      mainWindow.displayToast("활성 레이어가 없습니다.")
      return
    }

    var tl = mapCanvas.mapSettings.screenToCoordinate(Qt.point(point.x - 7, point.y - 7))
    var br = mapCanvas.mapSettings.screenToCoordinate(Qt.point(point.x + 7, point.y + 7))
    var rect = GeometryUtils.createRectangleFromPoints(tl, br)
    var it = LayerUtils.createFeatureIteratorFromRectangle(layer, rect)

    while (it.hasNext()) {
      var f = it.next()
      var p = featurePnu(f)
      if (p) {
        currentPnu = p
        currentLayerName = layer.name
        resultText = "PNU " + p + "\n\n아래에서 조회할 항목을 선택하세요."
        mainWindow.displayToast("PNU 확인: " + p)
        resultDialog.open()
        return
      }
    }

    mainWindow.displayToast("탭한 위치에서 19자리 PNU를 찾지 못했습니다.")
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
        try {
          success(JSON.parse(xhr.responseText))
        } catch (e) {
          failure("JSON 응답 해석 실패")
        }
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

  function queryLand() {
    if (!settings.vworldKey.trim()) {
      mainWindow.displayToast("플러그인 설정에서 브이월드 API 키를 입력하세요.")
      settingsDialog.open()
      return
    }

    resultText = "토지이용계획 조회 중…"
    var url = "https://api.vworld.kr/ned/data/getLandUseAttr?format=json&key=" +
              encodeURIComponent(settings.vworldKey.trim()) +
              "&pnu=" + encodeURIComponent(currentPnu) +
              "&numOfRows=1000&pageNo=1"

    getJson(url, function(data) {
      var seen = {}
      var lines = []
      walk(data, function(o) {
        var name = first(o, ["prposAreaDstrcCodeNm", "prposAreaDstrcCode"])
        if (name && !seen[name]) {
          seen[name] = true
          lines.push("• " + name)
        }
      })
      resultText = lines.length
        ? "PNU " + currentPnu + "\n\n[토지이용계획]\n" + lines.join("\n")
        : "토지이용계획 지정내역을 찾지 못했습니다."
    }, function(err) {
      resultText = "토지이용계획 조회 실패\n" + err
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

    resultText = "건축물대장 조회 중…"
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
          var key = first(o, ["mgmBldrgstPk"]) || JSON.stringify(o)
          if (!seen[key]) {
            seen[key] = true
            rows.push(o)
          }
        }
      })

      if (!rows.length) {
        resultText = "건축물대장 표제부를 찾지 못했습니다."
        return
      }

      var blocks = []
      for (var i = 0; i < rows.length; i++) {
        var r = rows[i]
        blocks.push(
          (first(r, ["bldNm", "dongNm"]) || "건축물") +
          "\n소재지: " + (first(r, ["platPlc", "newPlatPlc"]) || "-") +
          "\n주용도: " + (first(r, ["mainPurpsCdNm", "etcPurps"]) || "-") +
          "\n구조: " + (first(r, ["strctCdNm", "etcStrct"]) || "-") +
          "\n건축면적: " + (first(r, ["archArea"]) || "-") + " ㎡" +
          "\n연면적: " + (first(r, ["totArea"]) || "-") + " ㎡" +
          "\n건폐율: " + (first(r, ["bcRat"]) || "-") + "%" +
          "\n용적률: " + (first(r, ["vlRat"]) || "-") + "%" +
          "\n지상/지하: " + (first(r, ["grndFlrCnt"]) || "-") + " / " + (first(r, ["ugrndFlrCnt"]) || "-") +
          "\n사용승인일: " + (first(r, ["useAprDay"]) || "-")
        )
      }

      resultText = "PNU " + currentPnu + "\n\n[건축물대장]\n" + blocks.join("\n\n────────\n\n")
    }, function(err) {
      resultText = "건축물대장 조회 실패\n" + err
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
    title: "토지·건축물 조회"
    width: Math.min(mainWindow.width * 0.92, 760)
    height: Math.min(mainWindow.height * 0.8, 760)
    x: (mainWindow.width - width) / 2
    y: (mainWindow.height - height) / 2
    standardButtons: Dialog.Close

    Column {
      width: parent.width
      height: parent.height
      spacing: 10

      Label {
        width: parent.width
        text: "PNU  " + currentPnu + "\n레이어  " + currentLayerName
        font.bold: true
        wrapMode: Text.WordWrap
      }

      Row {
        spacing: 8
        Button { text: "토지이용계획"; onClicked: plugin.queryLand() }
        Button { text: "건축물대장"; onClicked: plugin.queryBuilding() }
      }

      ScrollView {
        width: parent.width
        height: parent.height - 110
        TextArea {
          text: plugin.resultText
          readOnly: true
          wrapMode: TextEdit.Wrap
          selectByMouse: true
        }
      }
    }
  }
}
