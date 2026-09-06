import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The bar shows one colour: green while every site's platform requirements are
// met, red the moment one is not, and dimmed when the stack is deliberately
// down. Clicking opens a flyout listing the sites under management with their
// state, and a control to bring the stack up or down.
//
// Memory figures are not shown here on purpose: measuring the containers costs
// a ~2s `docker stats` sample, which is far too expensive for something polled
// every 15 seconds. `covey status` is where that question gets answered.
//
// Everything here comes from `covey doctor --json` - the same model the CLI and
// any agent read. This widget is a renderer, not a second source of truth.
BarWidget {
  id: root
  moduleName: "covey"

  property bool healthy: true
  property bool known: false
  property int failures: 0
  property string stackState: "up"   // up | degraded | down
  property bool acting: false        // an up/down is in flight
  property string actedFrom: ""
  property var sites: []            // [{name, url, php, ok, state}]
  property var platformIssues: []   // [{check, detail}]
  property string phpSummary: ""
  property string tooltip: "covey"
  property bool popupOpen: false

  function close() { popupOpen = false }
  function togglePopup() { popupOpen = !popupOpen }

  // Follow the bar's font so `omarchy font set` and theme overrides apply.
  readonly property string uiFont: bar ? bar.fontFamily : Style.font.family

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

    // An up/down takes seconds (docker compose --wait). Stop treating the
    // widget as in-flight as soon as the state we acted away from is gone.
    // Named `stackSt`, not `st`: the site loop below declares its own `st`,
    // and `var` is function-scoped, so the two would be the same variable.
    var stackSt = d.state ? String(d.state) : "up"
    if (root.acting && stackSt !== root.actedFrom) root.acting = false

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
    root.stackState = stackSt
    root.sites = list
    root.platformIssues = issues
    root.phpSummary = Object.keys(versions).sort().join(", ")
    root.failures = issues.length + list.filter(function (x) { return !x.ok }).length
    root.healthy = d.ok === true
    root.tooltip = stackSt === "down"
      ? "covey — stopped (click to start)"
      : (root.failures === 0
        ? "covey — " + list.length + " site" + (list.length === 1 ? "" : "s") + ", all checks passed"
        : "covey — " + root.failures + " problem" + (root.failures === 1 ? "" : "s") + " (click for detail)")
  }

  // Bring the stack up or down. covey drops doctor's cache on both, so the
  // follow-up polls see the new state rather than the cached old one.
  //
  // The command runs exactly once - on the instance that was clicked, or the
  // one instance whose IPC handler registered - and only the in-flight marker
  // is broadcast, so a two-monitor bar does not run `covey up` twice.
  function setStack(up) {
    Quickshell.execDetached([root.coveyBin, up ? "up" : "down"])
    root.broadcast("markActing")
  }

  // Zero-argument, because broadcast() calls its method with no arguments.
  function markActing() {
    root.actedFrom = root.stackState
    root.acting = true
    settle.ticks = 0
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh()

  IpcHandler {
    target: "covey"
    function refresh(): void { root.broadcast("refresh") }
    function toggle(): void { root.broadcast("togglePopup") }
    function up(): void { root.setStack(true) }
    function down(): void { root.setStack(false) }
  }

  // Poll faster than the normal interval while an up/down settles, then give up.
  Timer {
    id: settle
    property int ticks: 0
    interval: 1500
    repeat: true
    running: root.acting
    onTriggered: {
      ticks++
      root.refresh()
      if (ticks > 12) { root.acting = false; ticks = 0 }
    }
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
    // A stopped stack is not a problem, so it dims rather than turning red.
    // Opacity rather than a darker colour: `Qt.darker` reads as *more*
    // prominent against a light theme's dark foreground.
    opacity: root.stackState === "down" || root.acting ? 0.45 : 1.0
    active: !root.healthy && root.stackState !== "down" && !root.acting
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

      Item {
        width: parent.width
        height: header.implicitHeight

        PanelSectionHeader {
          id: header
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          foreground: Color.popups.text
          fontFamily: root.uiFont
          text: "SITES"
        }
        Text {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: root.stackState === "down" ? "stopped"
              : (root.phpSummary ? "php " + root.phpSummary : "")
          color: Qt.darker(Color.popups.text, 1.4)
          font.family: root.uiFont
          font.pixelSize: Style.font.caption
        }
      }

      PanelSeparator { width: parent.width }

      // One row per site: state dot, name, then version (healthy) or a short
      // problem label (not). Monospace keeps the right column aligned.
      Repeater {
        model: root.sites
        Item {
          width: column.width
          height: Style.space(22)

          Rectangle {
            id: dot
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(7)
            height: width
            radius: width / 2
            color: modelData.ok ? Qt.darker(Color.popups.text, 1.6) : Color.urgent
          }
          Text {
            id: nameText
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: dot.right
            anchors.leftMargin: Style.space(9)
            text: modelData.name
            color: Color.popups.text
            font.family: root.uiFont
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            width: Math.min(implicitWidth, parent.width * 0.45)
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            text: modelData.ok ? modelData.php : modelData.state
            color: modelData.ok ? Qt.darker(Color.popups.text, 1.5) : Color.urgent
            font.family: root.uiFont
            font.pixelSize: Style.font.bodySmall
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
        text: root.known ? "No sites yet \u2014 mkdir ~/Covey/<name>"
                         : "covey is not responding"
        color: Qt.darker(Color.popups.text, 1.4)
        font.family: root.uiFont
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      PanelSeparator { width: parent.width; visible: root.platformIssues.length > 0 }

      // Platform problems are not attributable to any one site.
      Repeater {
        model: root.platformIssues
        Text {
          width: column.width
          text: modelData.check + (modelData.detail ? "  " + modelData.detail : "")
          color: Color.urgent
          font.family: root.uiFont
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }

      PanelSeparator { width: parent.width }

      // The stack control. Leaving covey running costs a few hundred MiB, so
      // this is the switch for a day that is not a PHP day. `covey status` has
      // the figure; this just flips it.
      Item {
        width: parent.width
        height: Style.space(22)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: root.acting ? "Working\u2026"
              : root.stackState === "down" ? "Stack stopped"
              : root.stackState === "degraded" ? "Stack partly running"
              : "Stack running"
          color: root.stackState === "degraded" ? Color.urgent : Color.popups.text
          font.family: root.uiFont
          font.pixelSize: Style.font.bodySmall
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          anchors.right: parent.right
          visible: !root.acting
          text: root.stackState === "down" ? "Start \u2192" : "Stop \u2192"
          color: Qt.darker(Color.popups.text, 1.3)
          font.family: root.uiFont
          font.pixelSize: Style.font.bodySmall
        }
        MouseArea {
          anchors.fill: parent
          enabled: !root.acting && root.known
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            root.close()
            root.setStack(root.stackState === "down")
          }
        }
      }

      PanelSeparator { width: parent.width }

      Item {
        width: parent.width
        height: Style.space(20)
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: root.stackState === "down"
            ? "Runtime checks skipped"
            : (root.healthy
              ? "All checks passed"
              : root.failures + (root.failures === 1 ? " problem" : " problems"))
          color: (root.healthy || root.stackState === "down")
            ? Qt.darker(Color.popups.text, 1.4) : Color.urgent
          font.family: root.uiFont
          font.pixelSize: Style.font.caption
        }
        Text {
          id: reportLabel
          anchors.verticalCenter: parent.verticalCenter
          anchors.right: parent.right
          text: "Full report \u2192"
          color: Color.popups.text
          font.family: root.uiFont
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
