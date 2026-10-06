import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The bar shows one colour: green while every site's platform requirements are
// met, red the moment one is not, and dimmed when the stack is deliberately
// down. Clicking opens a flyout listing the sites under management with their
// state, a switch per site, and a control to bring the stack up or down.
//
// Memory figures are not shown here on purpose: measuring the containers costs
// a ~2s `docker stats` sample, which is far too expensive for something polled
// every 15 seconds. `covey status` is where that question gets answered.
//
// Everything here comes from `covey doctor --json` - the same model the CLI and
// any agent read. This widget is a renderer, not a second source of truth:
// every control runs a `covey` command, and nothing here writes covey's files.
BarWidget {
  id: root
  moduleName: "covey"

  property bool healthy: true
  property bool known: false
  property int failures: 0
  property string stackState: "up"   // up | degraded | down
  property bool acting: false        // an up/down is in flight
  property string actedFrom: ""
  property var sites: []            // [{name, url, path, php, ok, state, enabled}]
  property var platformIssues: []   // [{check, detail}]
  property string phpSummary: ""
  property string solo: ""           // the site `covey site solo` left running
  property string tooltip: "covey"
  property bool popupOpen: false
  property bool showOff: false       // the "Off" group is expanded

  // Per-site commands queue here and run one at a time. The CLI also takes a
  // lock, but queueing keeps the switches' busy state honest.
  property var queue: []
  // name -> desired enabled, while a switch's command is queued or running.
  // The switch shows this value so the knob throws on click, not on refresh.
  property var pending: ({})
  readonly property var blankSite: ({ name: "", url: "", path: "", php: "", ok: true,
                                       state: "", enabled: true, share: "", shared: false })
  readonly property bool siteBusy: siteProc.running || root.queue.length > 0

  readonly property var liveSites: root.sites.filter(function (x) { return x.enabled })
  readonly property var offSites: root.sites.filter(function (x) { return !x.enabled })
  // Live sites, then one "Off (n)" header, then - when expanded - the rest.
  readonly property var listModel: {
    var m = root.liveSites.map(function (x) { return { kind: "site", site: x } })
    if (root.offSites.length > 0) {
      m.push({ kind: "off" })
      if (root.showOff) m = m.concat(root.offSites.map(function (x) { return { kind: "site", site: x } }))
    }
    return m
  }

  function close() { popupOpen = false }
  function togglePopup() { popupOpen = !popupOpen }

  // Follow the bar's font so `omarchy font set` and theme overrides apply.
  readonly property string uiFont: bar ? bar.fontFamily : Style.font.family

  readonly property string coveyBin: Quickshell.env("HOME") + "/.local/share/covey/bin/covey"
  readonly property int refreshSec: settings && settings.refreshIntervalSec
    ? Number(settings.refreshIntervalSec) : 15

  // A refresh asked for while one is running is not dropped: the running one
  // may have read the model from before a site command finished.
  property bool refreshAgain: false
  function refresh() {
    if (doctorProc.running) root.refreshAgain = true
    else doctorProc.running = true
  }

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
      // A site taken down with `covey site down` is off on purpose: it dims
      // rather than turning red, and its version does not appear in the header
      // summary because no pool is being kept alive for it.
      var live = site.enabled !== false
      if (live) versions[ver] = true
      list.push({ name: String(site.name), url: String(site.url),
                  path: String(site.path || ""),
                  share: site.share && site.share.state !== "failed" ? String(site.share.url || "") : "",
                  shared: !!(site.share && site.share.state !== "failed"),
                  php: ver, ok: st.ok, state: st.text, enabled: live })
    }

    root.known = true
    root.stackState = stackSt
    root.sites = list
    root.solo = d.solo ? String(d.solo) : ""
    root.platformIssues = issues
    root.phpSummary = Object.keys(versions).sort().join(", ")
    root.failures = issues.length + list.filter(function (x) { return !x.ok }).length
    root.healthy = d.ok === true
    // Only once every queued command has finished is the model the truth;
    // before that it can predate a switch that was just flipped.
    if (!root.siteBusy) { root.pending = ({}); root.sharing = ({}) }
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
  // The settings pane is this plugin's overlay, owned by the shell's panel
  // loader rather than by any one bar instance.
  function openSettings(tab) {
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", "covey",
                             JSON.stringify(tab ? { tab: tab } : {})])
  }

  function markActing() {
    root.actedFrom = root.stackState
    root.acting = true
    settle.ticks = 0
  }

  // Per-site commands. Like setStack, these run once, on the clicked instance;
  // when the queue drains, every instance is told to refresh. `covey sync`
  // drops doctor's cache, so that refresh reads the new model.
  function runSite(args) { runCovey(["site"].concat(args)) }
  function runCovey(args) {
    root.queue = root.queue.concat([args])
    if (!siteProc.running) runNext()
  }
  // Sharing takes several seconds (tunnel up, then public DNS). Mark the row
  // until the model says it changed.
  property var sharing: ({})
  function setShare(name, on) {
    var m = Object.assign({}, root.sharing); m[name] = true; root.sharing = m
    runCovey(on ? ["share", name] : ["unshare", name])
  }
  function runNext() {
    if (root.queue.length === 0) { root.broadcast("refresh"); return }
    var next = root.queue[0]
    root.queue = root.queue.slice(1)
    siteProc.command = [root.coveyBin].concat(next)
    siteProc.running = true
  }
  function setSite(name, up) {
    var p = Object.assign({}, root.pending)
    p[name] = up
    root.pending = p
    runSite([up ? "up" : "down", name])
  }
  function enabledOf(site) {
    return root.pending[site.name] !== undefined ? root.pending[site.name] : site.enabled
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
    function settings(): void { root.openSettings("") }
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
      if (root.refreshAgain) { root.refreshAgain = false; root.refresh() }
    }
  }

  Process {
    id: siteProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim()) console.warn("covey:", text.trim())
    }
    onExited: root.runNext()
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
    // nf-fa-server. Escaped, not literal: a private-use glyph is invisible in
    // most tool output, and a rewrite once dropped it without anyone noticing.
    text: "\uf233"
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

  // A small text action: the flyout's links ("Restore →", "solo", ...).
  // An inline component does not share this file's id scope, so it cannot see
  // `root`: callers set the font family.
  component LinkText: Text {
    id: link
    signal activated()
    property color baseColor: Qt.darker(Color.popups.text, 1.3)
    color: linkMouse.containsMouse ? Color.popups.text : baseColor
    font.pixelSize: Style.font.caption
    MouseArea {
      id: linkMouse
      anchors.fill: parent
      anchors.margins: -Style.space(3)
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: link.activated()
    }
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(380))
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

      // Solo mode is a temporary state, so it says how to leave it.
      Item {
        width: parent.width
        height: Style.space(20)
        visible: root.solo !== ""
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "Solo: " + root.solo
          color: Color.popups.text
          font.family: root.uiFont
          font.pixelSize: Style.font.bodySmall
        }
        LinkText {
          anchors.verticalCenter: parent.verticalCenter
          anchors.right: parent.right
          text: "Restore →"
          font.family: root.uiFont
          onActivated: root.runSite(["restore"])
        }
      }

      // The list scrolls rather than growing the card past the screen.
      Flickable {
        width: parent.width
        height: Math.min(siteCol.implicitHeight, Style.space(24) * 16)
        contentHeight: siteCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        visible: root.sites.length > 0

        Column {
          id: siteCol
          width: column.width

          // One site: state dot, name (opens it), then either its version or
          // problem, or - under the cursor - its actions; and a switch that
          // takes it in or out of service with `covey site up|down`. Sites
          // that are off on purpose fold away under one header: with solo on,
          // that is every site but one, and none of them needs attention.
          Repeater {
            model: root.listModel
            Item {
              width: column.width
              height: modelData.kind === "site" ? siteRow.height : offHeader.height

              Item {
                id: offHeader
                width: column.width
                height: Style.space(24)
                visible: modelData.kind === "off"
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: (root.showOff ? "\u25be" : "\u25b8") + "  Off (" + root.offSites.length + ")"
                  color: Qt.darker(Color.popups.text, 1.4)
                  font.family: root.uiFont
                  font.pixelSize: Style.font.bodySmall
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.showOff = !root.showOff
                }
              }

              Item {
                id: siteRow
                // The "Off" header entry has no site; a blank one keeps this
                // hidden row's bindings from evaluating to undefined.
                readonly property var site: modelData.site || root.blankSite
                readonly property bool on: root.enabledOf(site)
                readonly property bool hot: rowHover.hovered

                width: column.width
                height: Style.space(24)
                visible: modelData.kind === "site"

                HoverHandler { id: rowHover }

                Rectangle {
                  id: dot
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(7)
                  height: width
                  radius: width / 2
                  color: (siteRow.site.ok || !siteRow.site.enabled)
                           ? Qt.darker(Color.popups.text, 1.6) : Color.urgent
                  opacity: siteRow.site.enabled ? 1.0 : 0.45
                }
                Text {
                  id: nameText
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.left: dot.right
                  anchors.leftMargin: Style.space(9)
                  text: siteRow.site.name
                  color: Color.popups.text
                  opacity: siteRow.site.enabled ? 1.0 : 0.45
                  font.family: root.uiFont
                  font.pixelSize: Style.font.bodySmall
                  font.underline: nameMouse.containsMouse
                  elide: Text.ElideRight
                  width: Math.min(implicitWidth, siteRow.width - right.width - Style.space(28))
                  MouseArea {
                    id: nameMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.close()
                      Quickshell.execDetached(["xdg-open", siteRow.site.url])
                    }
                  }
                }

                Row {
                  id: right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.right: parent.right
                  spacing: Style.space(10)

                  // Resting: what the site is running, or what is wrong with it.
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !siteRow.hot
                    text: root.sharing[siteRow.site.name] ? "sharing\u2026"
                        : !siteRow.site.enabled ? "off"
                        : !siteRow.site.ok ? siteRow.site.state
                        : siteRow.site.shared ? "shared" : siteRow.site.php
                    color: (siteRow.site.ok || !siteRow.site.enabled)
                             ? Qt.darker(Color.popups.text, 1.5) : Color.urgent
                    font.family: root.uiFont
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, column.width * 0.4)
                    horizontalAlignment: Text.AlignRight
                  }

                  // Under the cursor: actions. Solo is the one you reach for with many
                  // projects checked out - everything else off, restorable in one click.
                  LinkText {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: siteRow.hot && root.solo !== siteRow.site.name
                    text: "solo"
                    font.family: root.uiFont
                    onActivated: root.runSite(["solo", siteRow.site.name])
                  }
                  // Sharing puts the site on a public URL (cloudflared); `link`
                  // copies that URL. Only an enabled site can be shared.
                  LinkText {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: siteRow.hot && siteRow.site.enabled && root.stackState !== "down"
                             && !root.sharing[siteRow.site.name]
                    text: siteRow.site.shared ? "unshare" : "share"
                    font.family: root.uiFont
                    onActivated: root.setShare(siteRow.site.name, !siteRow.site.shared)
                  }
                  LinkText {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: siteRow.hot && siteRow.site.share !== ""
                    text: "link"
                    font.family: root.uiFont
                    onActivated: Quickshell.execDetached(["wl-copy", siteRow.site.share])
                  }
                  LinkText {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: siteRow.hot && siteRow.site.path !== ""
                    text: "term"
                    font.family: root.uiFont
                    onActivated: {
                      root.close()
                      Quickshell.execDetached(["setsid", "uwsm-app", "--", "xdg-terminal-exec",
                                               "--dir=" + siteRow.site.path])
                    }
                  }
                  LinkText {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: siteRow.hot
                    text: "copy"
                    font.family: root.uiFont
                    onActivated: Quickshell.execDetached(["wl-copy", siteRow.site.url])
                  }

                  ToggleSwitch {
                    anchors.verticalCenter: parent.verticalCenter
                    trackHeight: Style.space(14)
                    cursorPad: Style.space(2)
                    foreground: Color.popups.text
                    checked: siteRow.on
                    busy: root.pending[siteRow.site.name] !== undefined
                    onToggled: root.setSite(siteRow.site.name, !siteRow.on)
                  }
                }
              }
            }
          }
        }
      }

      Text {
        visible: root.sites.length === 0
        width: parent.width
        text: root.known ? "No sites yet — mkdir ~/Covey/<name>"
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
          text: root.acting ? "Working…"
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
          text: root.stackState === "down" ? "Start →" : "Stop →"
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
        // The problem count opens the full report; Settings opens the pane.
        MouseArea {
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: parent.width / 2
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            root.close()
            Quickshell.execDetached(
              ["omarchy-launch-floating-terminal-with-presentation", "covey", "doctor"])
          }
        }
        LinkText {
          anchors.verticalCenter: parent.verticalCenter
          anchors.right: parent.right
          text: "Settings →"
          font.family: root.uiFont
          baseColor: Color.popups.text
          onActivated: { root.close(); root.openSettings("") }
        }
      }
    }
  }
}
