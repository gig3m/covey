import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The bar shows one colour: green while every site's platform requirements are
// met, red the moment one is not. Clicking opens a flyout listing the sites
// under management with their state.
//
// Everything here comes from `covey doctor --json` - the same model the CLI and
// any agent read. This widget is a renderer, not a second source of truth.
BarWidget {
  id: root
  moduleName: "covey"

  property bool healthy: true
  property bool known: false
  property int failures: 0
  property var sites: []            // [{name, url, php, ok, state}]
  property var platformIssues: []   // [{check, detail}]
  property string phpSummary: ""
  property string tooltip: "covey"
  property bool popupOpen: false

  function close() { popupOpen = false }
  function togglePopup() { popupOpen = !popupOpen }

  readonly property string coveyBin: Quickshell.env("HOME") + "/.local/share/covey/bin/covey"
  readonly property int refreshSec: settings && settings.refreshIntervalSec
    ? Number(settings.refreshIntervalSec) : 15

  function refresh() { if (!doctorProc.running) doctorProc.running = true }

  // Short labels keyed on the stable `problem` code. The flyout wants a state,
  // not a sentence - full detail lives in `covey doctor`.
  readonly property var stateLabels: ({
    "provider_not_installed":   "php not installed",
    "no_provider":              "no php provider",
    "constraint_unsatisfiable": "php unsatisfied",
    "extensions_missing":       "extensions missing",
    "platform_reqs_missing":    "missing extension",
    "database_missing":         "no database",
    "service_down":             "service down",
    "docker_unavailable":       "docker down",
    "caddy_inactive":           "web server down",
    "pool_inactive":            "php pool down",
    "tls_untrusted":            "cert untrusted",
    "ca_untrusted_by_browsers": "cert untrusted",
    "http_failed":              "unreachable"
  })

  // First failing check is the site's state; otherwise "ok".
  function stateOf(checks) {
    for (var i = 0; i < checks.length; i++) {
      if (!checks[i].ok) {
        var c = checks[i]
        var label = root.stateLabels[String(c.problem)]
        if (!label) label = c.detail ? String(c.detail) : String(c.check)
        return { ok: false, text: label }
      }
    }
    return { ok: true, text: "ok" }
  }

  function update(raw) {
    var d
    try { d = JSON.parse(raw) } catch (e) { d = null }
    if (!d || !d.platform) {
      root.known = false; root.healthy = false
      root.sites = []; root.platformIssues = []
      root.failures = 0
      root.tooltip = "covey — could not read doctor output"
      return
    }

    var issues = []
    for (var i = 0; i < d.platform.length; i++) {
      var pc = d.platform[i]
      if (!pc.ok) issues.push({ check: String(pc.check), detail: String(pc.detail || "") })
    }

    var list = [], versions = {}
    for (var s = 0; s < d.sites.length; s++) {
      var site = d.sites[s]
      var st = stateOf(site.checks || [])
      var ver = site.php && site.php.series ? String(site.php.series) : "?"
      versions[ver] = true
      list.push({ name: String(site.name), url: String(site.url),
                  php: ver, ok: st.ok, state: st.text })
    }

    root.known = true
    root.sites = list
    root.platformIssues = issues
    root.phpSummary = Object.keys(versions).sort().join(", ")
    root.failures = issues.length + list.filter(function (x) { return !x.ok }).length
    root.healthy = d.ok === true
    root.tooltip = root.failures === 0
      ? "covey — " + list.length + " site" + (list.length === 1 ? "" : "s") + ", all checks passed"
      : "covey — " + root.failures + " problem" + (root.failures === 1 ? "" : "s") + " (click for detail)"
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh()

  IpcHandler {
    target: "covey"
    function refresh(): void { root.broadcast("refresh") }
    function toggle(): void { root.broadcast("togglePopup") }
  }

  Process {
    id: doctorProc
    command: [root.coveyBin, "doctor", "--json", "--cached", String(root.refreshSec)]
    stdout: StdioCollector {
      waitForEnd: true
      // doctor exits 1 when something fails, so parse stdout regardless of code.
      onStreamFinished: root.update(text)
    }
    onExited: function (exitCode) {
      if (exitCode !== 0 && exitCode !== 1) {
        root.known = false; root.healthy = false
        root.sites = []
        root.tooltip = "covey — doctor could not run (is covey installed?)"
      }
    }
  }

  Timer {
    interval: Math.max(5, root.refreshSec) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: root.tooltip
    active: !root.healthy
    useActiveColor: true
    activeColor: Color.urgent
    onPressed: root.popupOpen = !root.popupOpen
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(340))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(6)

      Row {
        width: parent.width
        Text {
          text: "Sites"
          color: Color.popups.text
          font.pixelSize: Style.font.caption
          font.bold: true
        }
        Item { width: parent.width - 120; height: 1 }
        Text {
          text: root.phpSummary ? "php " + root.phpSummary : ""
          color: Color.muted
          font.pixelSize: Style.font.caption
        }
      }

      PanelSeparator { width: parent.width }

      // One row per site under management: state dot, name, version, state.
      Repeater {
        model: root.sites
        Item {
          width: column.width
          height: Style.space(20)

          Text {
            id: dot
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.ok ? "●" : "●"
            color: modelData.ok ? Color.popups.text : Color.urgent
            font.pixelSize: Style.font.caption
            opacity: modelData.ok ? 0.55 : 1.0
          }
          Text {
            id: nameText
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: dot.right
            anchors.leftMargin: Style.space(8)
            text: modelData.name
            color: Color.popups.text
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: Math.min(implicitWidth, parent.width * 0.42)
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            text: modelData.ok ? modelData.php : modelData.state
            color: modelData.ok ? Color.muted : Color.urgent
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: Math.min(implicitWidth, parent.width * 0.5)
            horizontalAlignment: Text.AlignRight
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              root.close()
              Quickshell.execDetached(["xdg-open", modelData.url])
            }
          }
        }
      }

      Text {
        visible: root.sites.length === 0
        width: parent.width
        text: root.known ? "No sites yet — mkdir ~/Covey/<name>" : "covey is not responding"
        color: Color.muted
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      PanelSeparator { width: parent.width; visible: root.platformIssues.length > 0 }

      // Platform problems are not attributable to any one site.
      Repeater {
        model: root.platformIssues
        Text {
          width: column.width
          text: "✗ " + modelData.check + (modelData.detail ? " — " + modelData.detail : "")
          color: Color.urgent
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      PanelSeparator { width: parent.width }

      Item {
        width: parent.width
        height: Style.space(20)
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: root.healthy ? "All checks passed" : root.failures + " problem"
                + (root.failures === 1 ? "" : "s")
          color: root.healthy ? Color.muted : Color.urgent
          font.pixelSize: Style.font.caption
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          anchors.right: parent.right
          text: "Full report →"
          color: Color.popups.text
          font.pixelSize: Style.font.caption
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            root.close()
            Quickshell.execDetached(
              ["omarchy-launch-floating-terminal-with-presentation", "covey", "doctor"])
          }
        }
      }
    }
  }
}
