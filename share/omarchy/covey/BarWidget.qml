import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The bar's job is one colour and one click: green while every site's platform
// requirements are met, red the moment one is not. The detail lives in the
// tooltip, and the full report is one click away.
//
// Everything shown here comes from `covey doctor --json`, the same model the
// CLI and any agent read - the bar is a renderer, not a second source of truth.
BarWidget {
  id: root
  moduleName: "covey"

  property bool healthy: true
  property bool known: false
  property int failures: 0
  property int siteCount: 0
  property string tooltip: "covey"

  readonly property string coveyBin: Quickshell.env("HOME") + "/.local/share/covey/bin/covey"
  readonly property int refreshSec: settings && settings.refreshIntervalSec
    ? Number(settings.refreshIntervalSec) : 15

  function refresh() { if (!doctorProc.running) doctorProc.running = true }

  function describe(scope, c) {
    var s = "✗ " + (scope ? scope + " / " : "") + c.check
    if (c.detail) s += ": " + c.detail
    if (c.fix && c.fix.cmd) s += "\n    fix: " + c.fix.cmd + (c.fix.needs_root ? " (root)" : "")
    else if (c.hint) s += "\n    " + c.hint
    return s
  }

  function update(raw) {
    var d
    try { d = JSON.parse(raw) } catch (e) { d = null }
    if (!d || !d.platform) {
      root.known = false
      root.healthy = false
      root.failures = 0
      root.tooltip = "covey: could not read doctor output"
      return
    }
    var lines = []
    for (var i = 0; i < d.platform.length; i++)
      if (!d.platform[i].ok) lines.push(describe("", d.platform[i]))
    for (var s = 0; s < d.sites.length; s++) {
      var site = d.sites[s]
      for (var j = 0; j < site.checks.length; j++)
        if (!site.checks[j].ok) lines.push(describe(site.name, site.checks[j]))
    }
    root.known = true
    root.siteCount = d.sites.length
    root.failures = lines.length
    root.healthy = d.ok === true
    root.tooltip = lines.length === 0
      ? "covey — " + d.sites.length + " site" + (d.sites.length === 1 ? "" : "s") + ", all checks passed"
      : "covey — " + lines.length + " problem" + (lines.length === 1 ? "" : "s") + "\n\n" + lines.join("\n")
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh()

  IpcHandler {
    target: "covey"
    function refresh(): void { root.broadcast("refresh") }
  }

  Process {
    id: doctorProc
    command: [root.coveyBin, "doctor", "--json", "--cached", String(root.refreshSec)]
    stdout: StdioCollector {
      waitForEnd: true
      // doctor exits 1 when something fails, so parse stdout regardless of code.
      onStreamFinished: root.update(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && exitCode !== 1) {
        root.known = false
        root.healthy = false
        root.tooltip = "covey: doctor could not run (is covey installed?)"
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
    onPressed: Quickshell.execDetached(
      ["omarchy-launch-floating-terminal-with-presentation", "covey", "doctor"])
  }
}
