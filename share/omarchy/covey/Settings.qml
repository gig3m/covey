import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// covey's settings window: the Herd-style pane. Opened from the flyout's
// "Settings" link or `omarchy-shell shell toggle covey '{}'` (a payload of
// {"tab": "services"} opens a given tab).
//
// Like the bar widget it is a renderer, never a source of truth. It reads two
// models - `covey status --json` (what covey provides) and `covey doctor
// --json` (whether it is right) - and every button runs a `covey` command, so
// there is nothing here an agent cannot also do from the CLI. Commands that
// need root open in a terminal, where sudo can ask for a password.
//
// Rows that need this file's ids are written out as delegates rather than
// inline components: an inline component does not share the file's id scope.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property int tab: 0
  readonly property var tabs: ["Sites", "Services", "PHP", "General"]

  property var status: null          // covey status --json
  property var doctor: null          // covey doctor --json
  property var databases: []         // covey db list
  property string selectedSite: ""
  property var queue: []
  property string lastError: ""
  // True while a text field has focus. Polling pauses so a refresh (which
  // rebuilds the rows) cannot wipe a value half-typed.
  property bool editing: false

  readonly property string coveyBin: Quickshell.env("HOME") + "/.local/share/covey/bin/covey"
  readonly property string uiFont: Style.font.family
  readonly property color fg: Color.popups.text
  readonly property color dim: Qt.darker(Color.popups.text, 1.5)
  readonly property bool busy: cmdProc.running || root.queue.length > 0

  readonly property var sites: root.doctor && root.doctor.sites ? root.doctor.sites : []
  readonly property var site: {
    for (var i = 0; i < root.sites.length; i++)
      if (root.sites[i].name === root.selectedSite) return root.sites[i]
    return root.sites.length > 0 ? root.sites[0] : null
  }
  readonly property string stackState: root.doctor && root.doctor.state ? String(root.doctor.state) : "down"
  readonly property string solo: root.doctor && root.doctor.solo ? String(root.doctor.solo) : ""

  // ---- lifecycle -----------------------------------------------------------
  function open(payloadJson) {
    var p = null
    try { p = JSON.parse(payloadJson || "{}") } catch (e) { p = null }
    if (p && p.tab) {
      var idx = root.tabs.map(function (t) { return t.toLowerCase() }).indexOf(String(p.tab).toLowerCase())
      if (idx >= 0) root.tab = idx
    }
    if (p && p.site) root.selectedSite = String(p.site)
    root.opened = true
    root.refresh()
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }
  function close() { root.opened = false }
  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "covey")
  }
  function toggle() { if (root.opened) root.dismiss(); else root.open("{}") }

  // ---- data ----------------------------------------------------------------
  // Status runs twice: once without containers (instant), then with them,
  // which costs a ~2s `docker stats` sample and fills in service memory.
  function refresh() {
    if (!quickStatus.running) quickStatus.running = true
    if (!doctorProc.running) doctorProc.running = true
    if (!dbProc.running) dbProc.running = true
  }
  function parse(text) {
    try { return JSON.parse(text) } catch (e) { return null }
  }

  // ---- actions -------------------------------------------------------------
  // Mutations queue and run one at a time; when the queue drains, the pane
  // re-reads both models and the bar is told to refresh too.
  function run(args) {
    root.queue = root.queue.concat([args])
    if (!cmdProc.running) runNext()
  }
  function runNext() {
    if (root.queue.length === 0) {
      root.refresh()
      Quickshell.execDetached(["omarchy-shell", "covey", "refresh"])
      return
    }
    var next = root.queue[0]
    root.queue = root.queue.slice(1)
    cmdProc.command = [root.coveyBin].concat(next)
    cmdProc.running = true
  }
  // For anything that needs root or is interactive: a terminal, so sudo can
  // prompt and the output stays readable.
  function inTerminal(cmd) {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", cmd])
  }
  function openUrl(u) { Quickshell.execDetached(["xdg-open", u]) }
  function copy(text) { Quickshell.execDetached(["wl-copy", "--", text]) }
  function terminalAt(dir) {
    Quickshell.execDetached(["setsid", "uwsm-app", "--", "xdg-terminal-exec", "--dir=" + dir])
  }

  // ---- presentation helpers ------------------------------------------------
  function mib(b) { return b === null || b === undefined ? "-" : Math.round(b / 1048576) + " MiB" }
  function failing(checks) { return (checks || []).filter(function (c) { return !c.ok }) }
  function siteState(s) {
    if (!s) return ""
    if (s.enabled === false) return "off"
    var bad = root.failing(s.checks)
    return bad.length ? String(bad[0].check) : (s.php && s.php.series ? s.php.series : "")
  }
  // How this site got its PHP version, and how to change it. covey never
  // edits a project, so the answer is always "edit this file, then sync".
  function phpExplainer(s) {
    if (!s || !s.php) return ""
    var p = s.php
    var where = s.path
    if (p.source === ".covey")
      return "Pinned by " + where + "/.covey (php = " + p.required + "). Change that line, then run covey sync. "
           + "Delete it to fall back to composer.json."
    if (p.source === "composer.json")
      return "From composer.json require.php \"" + p.required + "\": the default version if it satisfies the "
           + "constraint, otherwise the highest installed one that does. To pin a version, put php = 8.3 "
           + "in " + where + "/.covey, then run covey sync."
    return "No constraint, so the default (" + (root.status && root.status.settings
           ? root.status.settings.default_php : "") + "). To pin one, put php = 8.3 in " + where
           + "/.covey, or set require.php in composer.json, then run covey sync."
  }
  function check(name) {
    var pl = root.doctor && root.doctor.platform ? root.doctor.platform : []
    for (var i = 0; i < pl.length; i++) if (pl[i].check === name) return pl[i]
    return null
  }

  // ---- processes -----------------------------------------------------------
  Process {
    id: quickStatus
    command: [root.coveyBin, "status", "--json", "--no-containers"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var d = root.parse(text)
        // Keep memory figures from a previous full read rather than blanking them.
        if (d && root.status && root.status.services) {
          for (var i = 0; i < d.services.length; i++)
            for (var j = 0; j < root.status.services.length; j++)
              if (root.status.services[j].name === d.services[i].name)
                d.services[i].bytes = root.status.services[j].bytes
        }
        if (d) root.status = d
      }
    }
    onExited: if (!fullStatus.running) fullStatus.running = true
  }
  Process {
    id: fullStatus
    command: [root.coveyBin, "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { var d = root.parse(text); if (d) root.status = d }
    }
  }
  Process {
    id: doctorProc
    command: [root.coveyBin, "doctor", "--json", "--cached", "15"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { var d = root.parse(text); if (d) root.doctor = d }
    }
  }
  Process {
    id: dbProc
    command: [root.coveyBin, "db", "list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.databases = text.split("\n").filter(function (l) { return l.trim() !== "" })
    }
    onExited: function (code) { if (code !== 0) root.databases = [] }
  }
  Process {
    id: cmdProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.lastError = text.trim()
    }
    onStarted: root.lastError = ""
    onExited: root.runNext()
  }

  // Poll while open so state changed elsewhere (the CLI, the bar) shows up.
  Timer {
    interval: 5000
    repeat: true
    running: root.opened && !root.editing
    onTriggered: root.refresh()
  }

  // ---- window --------------------------------------------------------------
  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "covey-settings"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: Color.menu.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: Math.min(Style.space(900), panel.width - Style.gapsOut * 4)
      height: Math.min(Style.space(620), panel.height - Style.gapsOut * 4)
      anchors.centerIn: parent
      radius: Style.cornerRadius
      color: Color.popups.background
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; onClicked: keyCatcher.forceActiveFocus() }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.onPressed: function (event) {
          if (event.key === Qt.Key_Escape) { root.dismiss(); event.accepted = true }
          else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_4) {
            root.tab = event.key - Qt.Key_1; event.accepted = true
          } else if (event.key === Qt.Key_Tab) {
            root.tab = (root.tab + 1) % root.tabs.length; event.accepted = true
          } else if (root.tab === 0 && (event.key === Qt.Key_Down || event.key === Qt.Key_Up)) {
            var at = -1
            for (var i = 0; i < root.sites.length; i++) if (root.site && root.sites[i].name === root.site.name) at = i
            var nx = Math.max(0, Math.min(root.sites.length - 1, at + (event.key === Qt.Key_Down ? 1 : -1)))
            if (root.sites.length) root.selectedSite = root.sites[nx].name
            event.accepted = true
          }
        }
      }

      Column {
        id: body
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.md

        // Header: name, stack state, tabs.
        Item {
          width: parent.width
          height: Math.max(titleText.implicitHeight, tabRow.implicitHeight)

          Text {
            id: titleText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "covey"
            color: root.fg
            font.family: root.uiFont
            font.pixelSize: Style.font.heading
            font.bold: true
          }
          Text {
            anchors.left: titleText.right
            anchors.leftMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            text: root.busy ? "working…"
                : root.stackState === "up" ? "running"
                : root.stackState === "degraded" ? "partly running" : "stopped"
            color: root.stackState === "degraded" ? Color.urgent : root.dim
            font.family: root.uiFont
            font.pixelSize: Style.font.bodySmall
          }
          Row {
            id: tabRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)
            Repeater {
              model: root.tabs
              Button {
                text: (index + 1) + " " + modelData
                fontFamily: root.uiFont
                fontSize: Style.font.bodySmall
                foreground: root.fg
                selected: root.tab === index
                onClicked: root.tab = index
              }
            }
          }
        }

        PanelSeparator { width: parent.width }

        // The last command's error, when there was one. Commands report on
        // stderr; this is the only place a failed click would otherwise vanish.
        Text {
          width: parent.width
          visible: root.lastError !== ""
          text: root.lastError
          color: Color.urgent
          font.family: root.uiFont
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Item {
          id: page
          width: parent.width
          height: parent.height - y

          // ================================================== Sites
          Row {
            anchors.fill: parent
            visible: root.tab === 0
            spacing: Style.spacing.md

            ListView {
              id: siteList
              width: Style.space(230)
              height: parent.height
              clip: true
              model: root.sites
              boundsBehavior: Flickable.StopAtBounds
              delegate: Item {
                width: siteList.width
                height: Style.space(26)
                readonly property bool sel: root.site && root.site.name === modelData.name
                Rectangle {
                  anchors.fill: parent
                  radius: Style.cornerRadius
                  color: parent.sel ? Color.menu.selectedBackground : "transparent"
                }
                Rectangle {
                  id: sdot
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(7); height: width; radius: width / 2
                  color: modelData.enabled === false || root.failing(modelData.checks).length === 0
                    ? root.dim : Color.urgent
                  opacity: modelData.enabled === false ? 0.45 : 1
                }
                Text {
                  anchors.left: sdot.right
                  anchors.leftMargin: Style.space(8)
                  anchors.right: sstate.left
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.name
                  color: parent.sel ? Color.menu.selectedText : root.fg
                  opacity: modelData.enabled === false ? 0.5 : 1
                  font.family: root.uiFont
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
                Text {
                  id: sstate
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.solo === modelData.name ? "solo" : root.siteState(modelData)
                  color: modelData.enabled !== false && root.failing(modelData.checks).length
                    ? Color.urgent : root.dim
                  font.family: root.uiFont
                  font.pixelSize: Style.font.caption
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.selectedSite = modelData.name
                }
              }
            }

            Rectangle { width: 1; height: parent.height; color: Qt.darker(root.fg, 3) }

            Flickable {
              width: parent.width - siteList.width - Style.spacing.md * 2 - 1
              height: parent.height
              contentHeight: detail.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              Column {
                id: detail
                width: parent.width
                spacing: Style.space(10)
                visible: root.site !== null

                Item {
                  width: parent.width
                  height: Math.max(siteName.implicitHeight, enSwitch.implicitHeight)
                  Text {
                    id: siteName
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.site ? root.site.name : ""
                    color: root.fg
                    font.family: root.uiFont
                    font.pixelSize: Style.font.title
                    font.bold: true
                  }
                  Text {
                    anchors.right: enSwitch.left
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.site && root.site.enabled === false ? "off" : "serving"
                    color: root.dim
                    font.family: root.uiFont
                    font.pixelSize: Style.font.bodySmall
                  }
                  ToggleSwitch {
                    id: enSwitch
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    foreground: root.fg
                    checked: root.site ? root.site.enabled !== false : false
                    busy: root.busy
                    onToggled: if (root.site) root.run(["site", root.site.enabled === false ? "up" : "down", root.site.name])
                  }
                }

                Text {
                  width: parent.width
                  text: root.site ? root.site.url + "\n" + root.site.path : ""
                  color: root.dim
                  font.family: root.uiFont
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WrapAnywhere
                }

                Flow {
                  width: parent.width
                  spacing: Style.space(6)
                  Button {
                    text: "Open"; bordered: true; fontFamily: root.uiFont; fontSize: Style.font.bodySmall; foreground: root.fg
                    onClicked: { root.openUrl(root.site.url); root.dismiss() }
                  }
                  Button {
                    text: "Terminal"; bordered: true; fontFamily: root.uiFont; fontSize: Style.font.bodySmall; foreground: root.fg
                    onClicked: { root.terminalAt(root.site.path); root.dismiss() }
                  }
                  Button {
                    text: "Copy URL"; bordered: true; fontFamily: root.uiFont; fontSize: Style.font.bodySmall; foreground: root.fg
                    onClicked: root.copy(root.site.url)
                  }
                  Button {
                    text: root.site && root.solo === root.site.name ? "End solo" : "Solo"
                    bordered: true; fontFamily: root.uiFont; fontSize: Style.font.bodySmall; foreground: root.fg
                    onClicked: root.run(root.solo === root.site.name ? ["site", "restore"] : ["site", "solo", root.site.name])
                  }
                }

                // Sharing: a public URL through the tunnel in share/tunnels.tsv.
                PanelSectionHeader { text: "SHARING"; foreground: root.fg; fontFamily: root.uiFont }
                Item {
                  width: parent.width
                  height: shareBtn.implicitHeight
                  readonly property var sh: root.site ? root.site.share : null
                  Text {
                    anchors.left: parent.left
                    anchors.right: shareBtn.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: !parent.sh ? (root.site && root.site.enabled === false ? "Turn the site on to share it."
                                        : "Not shared. Share puts it on a public trycloudflare.com URL.")
                        : parent.sh.state === "failed" ? "The tunnel stopped. Share again to retry."
                        : (parent.sh.url || "starting\u2026")
                    color: parent.sh && parent.sh.state === "failed" ? Color.urgent
                         : parent.sh ? root.fg : root.dim
                    font.family: root.uiFont
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }
                  Button {
                    id: shareBtn
                    anchors.right: parent.right
                    enabled: !root.busy && root.stackState !== "down" && !!root.site && root.site.enabled !== false
                    text: parent.sh && parent.sh.state !== "failed" ? "Stop sharing" : "Share"
                    bordered: true; fontFamily: root.uiFont; fontSize: Style.font.bodySmall; foreground: root.fg
                    onClicked: root.run(parent.sh && parent.sh.state !== "failed"
                                        ? ["unshare", root.site.name] : ["share", root.site.name])
                  }
                }
                Flow {
                  width: parent.width
                  spacing: Style.space(6)
                  visible: !!(root.site && root.site.share && root.site.share.url)
                  Button {
                    text: "Copy public URL"; bordered: true; fontFamily: root.uiFont; fontSize: Style.font.caption; foreground: root.fg
                    onClicked: root.copy(root.site.share.url)
                  }
                  Button {
                    text: "Open"; bordered: true; fontFamily: root.uiFont; fontSize: Style.font.caption; foreground: root.fg
                    onClicked: { root.openUrl(root.site.share.url); root.dismiss() }
                  }
                }
                Text {
                  width: parent.width
                  visible: !!(root.site && root.site.share)
                  text: "Anyone with the URL can reach this site. With APP_DEBUG=true an error page shows your .env."
                  color: root.dim
                  font.family: root.uiFont
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                PanelSectionHeader { text: "PHP"; foreground: root.fg; fontFamily: root.uiFont }
                Text {
                  width: parent.width
                  text: root.site && root.site.php
                    ? root.site.php.resolved + "  (from " + root.site.php.source + ")" : ""
                  color: root.fg
                  font.family: root.uiFont
                  font.pixelSize: Style.font.body
                }
                Text {
                  width: parent.width
                  text: root.phpExplainer(root.site)
                  color: root.dim
                  font.family: root.uiFont
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }

                PanelSectionHeader { text: "CHECKS"; foreground: root.fg; fontFamily: root.uiFont }
                Repeater {
                  model: root.site ? root.site.checks : []
                  Column {
                    width: detail.width
                    spacing: Style.space(2)
                    Text {
                      width: parent.width
                      text: (modelData.ok ? "ok    " : "fail  ") + modelData.check
                            + (modelData.detail ? "   " + modelData.detail : "")
                      color: modelData.ok ? root.fg : Color.urgent
                      font.family: root.uiFont
                      font.pixelSize: Style.font.bodySmall
                      wrapMode: Text.WordWrap
                    }
                    // A fix is a runnable command; offer to run it (in a
                    // terminal when it needs root). A hint is prose only.
                    Row {
                      visible: !modelData.ok && !!modelData.fix
                      spacing: Style.space(8)
                      leftPadding: Style.space(36)
                      Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.fix ? modelData.fix.cmd : ""
                        color: root.dim
                        font.family: root.uiFont
                        font.pixelSize: Style.font.bodySmall
                      }
                      Button {
                        text: "Run"; bordered: true; fontFamily: root.uiFont; fontSize: Style.font.caption; foreground: root.fg
                        onClicked: root.inTerminal(modelData.fix.cmd)
                      }
                    }
                    Text {
                      visible: !modelData.ok && !!modelData.hint
                      width: parent.width
                      leftPadding: Style.space(36)
                      text: modelData.hint || ""
                      color: root.dim
                      font.family: root.uiFont
                      font.pixelSize: Style.font.bodySmall
                      wrapMode: Text.WordWrap
                    }
                  }
                }
              }
            }
          }

          // ================================================== Services
          Flickable {
            anchors.fill: parent
            visible: root.tab === 1
            contentHeight: svcCol.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: svcCol
              width: parent.width
              spacing: Style.spacing.md

              Item {
                width: parent.width
                height: svcAll.implicitHeight
                Text {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Loopback only. Credentials match a stock Laravel .env."
                  color: root.dim
                  font.family: root.uiFont
                  font.pixelSize: Style.font.bodySmall
                }
                Button {
                  id: svcAll
                  anchors.right: parent.right
                  readonly property bool anyUp: root.status && root.status.services
                    ? root.status.services.some(function (s) { return s.up }) : false
                  text: anyUp ? "Stop services" : "Start services"
                  bordered: true; fontFamily: root.uiFont; fontSize: Style.font.bodySmall; foreground: root.fg
                  onClicked: root.run(["services", anyUp ? "down" : "up"])
                }
              }

              Grid {
                columns: 2
                columnSpacing: Style.spacing.md
                rowSpacing: Style.spacing.md
                width: parent.width

                Repeater {
                  model: root.status && root.status.services ? root.status.services : []
                  BorderSurface {
                    width: (svcCol.width - Style.spacing.md) / 2
                    height: svcCard.implicitHeight + Style.space(24)
                    radius: Style.cornerRadius
                    color: "transparent"
                    borderSpec: Border.controlSpec("normal", root.fg, Color.accent)

                    Column {
                      id: svcCard
                      x: Style.space(12); y: Style.space(12)
                      width: parent.width - Style.space(24)
                      spacing: Style.space(6)

                      Item {
                        width: parent.width
                        height: svcName.implicitHeight
                        Rectangle {
                          id: svcDot
                          anchors.verticalCenter: parent.verticalCenter
                          width: Style.space(7); height: width; radius: width / 2
                          color: modelData.up ? Color.accent : (root.stackState === "down" ? root.dim : Color.urgent)
                        }
                        Text {
                          id: svcName
                          anchors.left: svcDot.right
                          anchors.leftMargin: Style.space(8)
                          text: modelData.label
                          color: root.fg
                          font.family: root.uiFont
                          font.pixelSize: Style.font.subtitle
                          font.bold: true
                        }
                        Text {
                          anchors.right: parent.right
                          anchors.verticalCenter: parent.verticalCenter
                          text: (modelData.up ? "up" : "down") + (modelData.bytes ? "  " + root.mib(modelData.bytes) : "")
                          color: root.dim
                          font.family: root.uiFont
                          font.pixelSize: Style.font.caption
                        }
                      }
                      Text {
                        width: parent.width
                        text: modelData.host + ":" + modelData.port
                          + (modelData.user !== undefined
                             ? "   user " + modelData.user + ", password " + (modelData.password === "" ? "(empty)" : modelData.password)
                             : "")
                          + (modelData.image ? "\n" + modelData.image : "")
                        color: root.dim
                        font.family: root.uiFont
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.WrapAnywhere
                      }
                      Text {
                        visible: modelData.name === "mysql"
                        width: parent.width
                        text: "databases: " + (root.databases.length ? root.databases.join(", ") : "none")
                        color: root.dim
                        font.family: root.uiFont
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.WordWrap
                      }
                      Rectangle {
                        width: parent.width
                        height: envText.implicitHeight + Style.space(12)
                        radius: Style.cornerRadius
                        color: Color.menu.selectedBackground
                        Text {
                          id: envText
                          x: Style.space(6); y: Style.space(6)
                          width: parent.width - Style.space(12)
                          text: modelData.env.join("\n")
                          color: root.fg
                          font.family: root.uiFont
                          font.pixelSize: Style.font.bodySmall
                          wrapMode: Text.WrapAnywhere
                        }
                      }
                      Flow {
                        width: parent.width
                        spacing: Style.space(6)
                        Button {
                          text: "Copy .env"; bordered: true; fontFamily: root.uiFont; fontSize: Style.font.caption; foreground: root.fg
                          onClicked: root.copy(modelData.env.join("\n"))
                        }
                        Button {
                          visible: !!modelData.url
                          text: "Open"; bordered: true; fontFamily: root.uiFont; fontSize: Style.font.caption; foreground: root.fg
                          onClicked: { root.openUrl(modelData.url); root.dismiss() }
                        }
                        Button {
                          visible: !!modelData.shell
                          text: "Shell"; bordered: true; fontFamily: root.uiFont; fontSize: Style.font.caption; foreground: root.fg
                          onClicked: root.inTerminal(modelData.shell)
                        }
                      }
                    }
                  }
                }
              }

              Text {
                width: parent.width
                text: "Create a database with: covey db create <name>. covey never creates one on its own."
                color: root.dim
                font.family: root.uiFont
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
            }
          }

          // ================================================== PHP
          Flickable {
            anchors.fill: parent
            visible: root.tab === 2
            contentHeight: phpCol.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: phpCol
              width: parent.width
              spacing: Style.spacing.md

              Text {
                width: parent.width
                text: "How a site picks its version: php = X in the project's .covey, else composer.json "
                    + "require.php, else the default (" + (root.status && root.status.settings
                      ? root.status.settings.default_php : "") + "). covey reads these files and never "
                    + "writes them: change the project's file, then run covey sync."
                color: root.dim
                font.family: root.uiFont
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              PanelSectionHeader { text: "PHP.INI  (served sites, every version)"; foreground: root.fg; fontFamily: root.uiFont }

              // Enter applies a value; Reset returns it to covey's default. Each
              // change is `covey php set|unset`, which reloads the pools.
              Repeater {
                model: root.status && root.status.php_ini ? root.status.php_ini : []
                Item {
                  width: phpCol.width
                  height: iniField.implicitHeight
                  Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.key
                    color: root.fg
                    font.family: root.uiFont
                    font.pixelSize: Style.font.body
                  }
                  TextField {
                    id: iniField
                    x: Style.space(220)
                    width: Style.space(160)
                    text: modelData.value
                    font.family: root.uiFont
                    font.pixelSize: Style.font.body
                    foreground: root.fg
                    onActiveFocusChanged: root.editing = activeFocus
                    onAccepted: {
                      if (text.trim() !== "" && text.trim() !== modelData.value)
                        root.run(["php", "set", modelData.key, text.trim()])
                      keyCatcher.forceActiveFocus()
                    }
                    Keys.onEscapePressed: { text = modelData.value; keyCatcher.forceActiveFocus() }
                  }
                  Text {
                    anchors.left: iniField.right
                    anchors.leftMargin: Style.space(12)
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.custom
                      ? (modelData.default !== null ? "default " + modelData.default : "not a covey default")
                      : "default"
                    color: root.dim
                    font.family: root.uiFont
                    font.pixelSize: Style.font.bodySmall
                  }
                  Button {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: modelData.custom
                    text: modelData.default !== null ? "Reset" : "Remove"
                    bordered: true; fontFamily: root.uiFont; fontSize: Style.font.caption; foreground: root.fg
                    onClicked: root.run(["php", "unset", modelData.key])
                  }
                }
              }

              // Any other setting PHP knows; covey rejects names it does not.
              Item {
                width: phpCol.width
                height: newKey.implicitHeight
                TextField {
                  id: newKey
                  width: Style.space(208)
                  placeholderText: "other setting, e.g. date.timezone"
                  font.family: root.uiFont
                  font.pixelSize: Style.font.bodySmall
                  foreground: root.fg
                  onActiveFocusChanged: root.editing = activeFocus || newVal.activeFocus
                  onAccepted: newVal.forceActiveFocus()
                  Keys.onEscapePressed: keyCatcher.forceActiveFocus()
                }
                TextField {
                  id: newVal
                  x: Style.space(220)
                  width: Style.space(160)
                  placeholderText: "value"
                  font.family: root.uiFont
                  font.pixelSize: Style.font.bodySmall
                  foreground: root.fg
                  onActiveFocusChanged: root.editing = activeFocus || newKey.activeFocus
                  onAccepted: addIni.clicked()
                  Keys.onEscapePressed: keyCatcher.forceActiveFocus()
                }
                Button {
                  id: addIni
                  anchors.left: newVal.right
                  anchors.leftMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Set"; bordered: true; fontFamily: root.uiFont; fontSize: Style.font.caption; foreground: root.fg
                  onClicked: {
                    if (newKey.text.trim() === "" || newVal.text.trim() === "") return
                    root.run(["php", "set", newKey.text.trim(), newVal.text.trim()])
                    newKey.text = ""; newVal.text = ""
                    keyCatcher.forceActiveFocus()
                  }
                }
              }

              Text {
                width: parent.width
                text: "These reach sites served by covey. The php command line (artisan, composer) reads /etc/php as usual."
                color: root.dim
                font.family: root.uiFont
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              Repeater {
                model: root.status && root.status.php ? root.status.php : []
                Column {
                  id: phpBlock
                  width: phpCol.width
                  spacing: Style.space(6)
                  readonly property var missing: modelData.extensions
                    ? Object.keys(modelData.extensions).filter(function (k) { return !modelData.extensions[k] }) : []

                  PanelSeparator { width: parent.width }
                  Item {
                    width: parent.width
                    height: Math.max(phpTitle.implicitHeight, phpAct.implicitHeight)
                    Text {
                      id: phpTitle
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                      text: "PHP " + modelData.series + (modelData.version ? "   " + modelData.version : "")
                      color: root.fg
                      font.family: root.uiFont
                      font.pixelSize: Style.font.subtitle
                      font.bold: true
                    }
                    Text {
                      anchors.left: phpTitle.right
                      anchors.leftMargin: Style.space(12)
                      anchors.verticalCenter: parent.verticalCenter
                      text: !modelData.installed ? "not installed"
                          : (modelData.pool ? "pool running" : "pool stopped")
                      color: root.dim
                      font.family: root.uiFont
                      font.pixelSize: Style.font.bodySmall
                    }
                    Row {
                      id: phpAct
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(6)
                      Button {
                        visible: !modelData.installed
                        text: "Install"; bordered: true; fontFamily: root.uiFont; fontSize: Style.font.caption; foreground: root.fg
                        onClicked: root.inTerminal(modelData.install)
                      }
                      Button {
                        visible: modelData.installed && phpBlock.missing.length > 0
                        text: "Enable extensions"; bordered: true; fontFamily: root.uiFont; fontSize: Style.font.caption; foreground: root.fg
                        onClicked: root.inTerminal("covey php configure " + modelData.tag)
                      }
                    }
                  }
                  Text {
                    width: parent.width
                    visible: modelData.installed
                    text: modelData.sites.length
                      ? "Used by " + modelData.sites.join(", ")
                      : "No enabled site uses this version."
                    color: root.dim
                    font.family: root.uiFont
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                  }
                  Flow {
                    width: parent.width
                    spacing: Style.space(6)
                    visible: !!modelData.extensions
                    Repeater {
                      model: modelData.extensions
                        ? Object.keys(modelData.extensions).map(function (k) {
                            return { name: k, loaded: modelData.extensions[k] === true } })
                        : []
                      Rectangle {
                        readonly property bool loaded: modelData.loaded
                        width: extText.implicitWidth + Style.space(12)
                        height: extText.implicitHeight + Style.space(6)
                        radius: Style.cornerRadius
                        color: loaded ? Color.menu.selectedBackground : "transparent"
                        border.width: loaded ? 0 : 1
                        border.color: Color.urgent
                        Text {
                          id: extText
                          anchors.centerIn: parent
                          text: modelData.name
                          color: parent.loaded ? root.fg : Color.urgent
                          font.family: root.uiFont
                          font.pixelSize: Style.font.caption
                        }
                      }
                    }
                  }
                }
              }
            }
          }

          // ================================================== General
          Flickable {
            anchors.fill: parent
            visible: root.tab === 3
            contentHeight: genCol.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: genCol
              width: parent.width
              spacing: Style.space(12)

              // Label, value, and an optional control on the right.
              Repeater {
                model: [
                  { key: "stack" }, { key: "autostart" }, { key: "root" },
                  { key: "config" }, { key: "php" }, { key: "trust" }, { key: "ports" }
                ]
                Item {
                  width: genCol.width
                  height: Math.max(genLabel.implicitHeight + genValue.implicitHeight + Style.space(2),
                                   genBtn.implicitHeight, genSwitch.implicitHeight)
                  readonly property var st: root.status ? root.status.settings : null
                  readonly property var trust: root.check("browser-trust")
                  readonly property var row: {
                    var k = modelData.key
                    var s = st || {}
                    if (k === "stack") return { label: "Stack",
                      value: root.stackState === "up" ? "Running" : root.stackState === "degraded" ? "Partly running" : "Stopped",
                      button: root.stackState === "down" ? "Start" : "Stop",
                      act: function () { root.run([root.stackState === "down" ? "up" : "down"]) } }
                    if (k === "autostart") return { label: "Start at login",
                      value: s.autostart ? "covey.target starts when you log in" : "Start it yourself with covey up",
                      toggle: true, on: !!s.autostart,
                      act: function () { root.run(["autostart", s.autostart ? "off" : "on"]) } }
                    if (k === "root") return { label: "Sites folder",
                      value: (s.sites_root || "") + "  -  every directory in it is served at <name>.localhost",
                      button: "Open", act: function () { root.openUrl("file://" + s.sites_root); root.dismiss() } }
                    if (k === "config") return { label: "covey's own files",
                      value: (s.config_dir || "") + "  (generated Caddyfile, pools, the disabled list)" }
                    if (k === "php") return { label: "Default PHP", value: s.default_php || "" }
                    if (k === "trust") return { label: "Browser trust",
                      value: trust ? (trust.ok ? "Local CA trusted by browsers (NSS)" : String(trust.detail || "")) : "",
                      bad: trust && !trust.ok,
                      button: trust && !trust.ok ? "Fix" : "",
                      act: function () { root.inTerminal("covey trust") } }
                    if (k === "ports") return { label: "Ports 80 / 443",
                      value: s.unprivileged_port_start === null || s.unprivileged_port_start === undefined ? ""
                        : (s.unprivileged_port_start <= 80
                           ? "User services may bind them (ip_unprivileged_port_start = " + s.unprivileged_port_start + ")"
                           : "Blocked: needs net.ipv4.ip_unprivileged_port_start=80 (root)"),
                      bad: s.unprivileged_port_start > 80 }
                    return { label: k, value: "" }
                  }

                  Text {
                    id: genLabel
                    text: parent.row.label
                    color: root.fg
                    font.family: root.uiFont
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    id: genValue
                    anchors.top: genLabel.bottom
                    anchors.topMargin: Style.space(2)
                    width: parent.width - Style.space(120)
                    text: parent.row.value
                    color: parent.row.bad ? Color.urgent : root.dim
                    font.family: root.uiFont
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                  }
                  Button {
                    id: genBtn
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !!parent.row.button
                    text: parent.row.button || ""
                    bordered: true; fontFamily: root.uiFont; fontSize: Style.font.bodySmall; foreground: root.fg
                    onClicked: parent.row.act()
                  }
                  ToggleSwitch {
                    id: genSwitch
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !!parent.row.toggle
                    foreground: root.fg
                    checked: !!parent.row.on
                    busy: root.busy
                    onToggled: parent.row.act()
                  }
                }
              }

              PanelSeparator { width: parent.width }

              Flow {
                width: parent.width
                spacing: Style.space(6)
                Button {
                  text: "Full report"; bordered: true; fontFamily: root.uiFont; fontSize: Style.font.bodySmall; foreground: root.fg
                  onClicked: root.inTerminal("covey doctor")
                }
                Button {
                  text: "Web server log"; bordered: true; fontFamily: root.uiFont; fontSize: Style.font.bodySmall; foreground: root.fg
                  onClicked: root.inTerminal("covey logs caddy 200")
                }
                Button {
                  text: "PHP log"; bordered: true; fontFamily: root.uiFont; fontSize: Style.font.bodySmall; foreground: root.fg
                  onClicked: root.inTerminal("covey logs php 200")
                }
                Button {
                  text: "Services log"; bordered: true; fontFamily: root.uiFont; fontSize: Style.font.bodySmall; foreground: root.fg
                  onClicked: root.inTerminal("covey services logs 200")
                }
              }
            }
          }
        }
      }
    }
  }
}
