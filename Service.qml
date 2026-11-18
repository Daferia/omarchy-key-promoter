import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "Promoter.js" as Promoter

// Key Promoter: when you do something through the Omarchy menu, the app
// launcher or the dock that already has a keybinding, show the shortcut in a
// toast that stays for 15 seconds or until you close it.
//
// It never sees key presses. Instead it "arms" when something other than a
// keybinding is about to launch, then matches what happens next against your
// own Hyprland bindings:
//   - the Omarchy menu or the app grid closes (armed for `window` ms)
//   - a `uwsm-app -- gtk-launch` scope appears: only the shell's app list,
//     launcher grid and dock start apps that way, never a keybinding
//     (armed for `launchWindow` ms, since cold-starting apps can be slow)
// What happens next can be a window (app, web app, TUI), a shell layer
// (emojis, clipboard), or an omarchy-* script. Scripts additionally have to
// carry the shell's QS_* environment marker, which keybinding-started
// processes never have.
//
// Based on Forrest Knight's omarchy-key-promoter (MIT).
Item {
  id: service

  // Injected by omarchy-shell.
  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "daferia.key-promoter"
  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string statePath: home + "/.local/state/omarchy/key-promoter.json"

  // Settings, inline on this plugin's entry in ~/.config/omarchy/shell.json:
  //   { "id": "daferia.key-promoter", "duration": 15000, "position": "bottom-right", "window": 3000, "showCount": true }
  property int duration: 15000
  property string position: "bottom-right"
  readonly property var positions: ["top-left", "top-center", "top-right", "bottom-left", "bottom-center", "bottom-right"]
  property int window: 3000
  property int launchWindow: 10000
  property bool showCount: true

  // Layers whose closing means "the user picked something from a list".
  readonly property var launcherLayers: ["omarchy-menu", "omarchy-dock-apps"]

  property var binds: []
  property var counts: ({})
  property double armedUntil: 0
  property bool processArmed: false
  property int psRuns: 0
  property string lastEvent: ""

  readonly property string appSlice: {
    var m = /\/run\/user\/(\d+)/.exec(Quickshell.env("XDG_RUNTIME_DIR") || "")
    return m ? "/sys/fs/cgroup/user.slice/user-" + m[1] + ".slice/user@" + m[1] + ".service/app.slice/app-graphical.slice" : ""
  }
  // An environment variable only shell-started processes carry, read off this
  // very process so a future rename falls back gracefully.
  readonly property string shellMarker: {
    var names = ["QS_NO_RELOAD_POPUP", "QS_DISABLE_FILE_WATCHER"]
    for (var i = 0; i < names.length; i++) if (Quickshell.env(names[i])) return names[i]
    return ""
  }
  property bool launchWatchOk: false
  property int launchWatchRetries: 0

  function applySettings(raw) {
    try {
      var cfg = JSON.parse(raw || "{}")
      var list = Array.isArray(cfg.plugins) ? cfg.plugins : []
      for (var i = 0; i < list.length; i++) {
        var e = list[i]
        if (!e || e.id !== service.pluginId) continue
        if (e.duration !== undefined) duration = Math.max(1000, parseInt(e.duration, 10) || 15000)
        if (e.position !== undefined) {
          var pos = String(e.position)
          if (pos === "top" || pos === "bottom") pos += "-center"
          if (positions.indexOf(pos) !== -1) position = pos
        }
        if (e.window !== undefined) window = Math.max(500, parseInt(e.window, 10) || 3000)
        if (e.launchWindow !== undefined) launchWindow = Math.max(1000, parseInt(e.launchWindow, 10) || 10000)
        if (e.showCount !== undefined) showCount = e.showCount !== false
        return
      }
    } catch (err) {}
  }

  function loadBinds(raw) {
    try {
      binds = Promoter.prepare(JSON.parse(raw || "{}"))
    } catch (err) {
      console.warn("key-promoter: could not parse keybinds:", err)
    }
  }

  function loadCounts(raw) {
    try { counts = JSON.parse(raw || "{}") || {} } catch (err) { counts = {} }
  }

  function bump(combo) {
    var next = {}
    for (var k in counts) next[k] = counts[k]
    next[combo] = (next[combo] || 0) + 1
    counts = next
    stateFile.setText(JSON.stringify(counts, null, 2) + "\n")
    return next[combo]
  }

  function arm(ms, why, scanProcesses) {
    armedUntil = Math.max(armedUntil, Date.now() + ms)
    lastEvent = why
    if (scanProcesses) {
      processArmed = true
      psRuns = 0
      psTimer.restart()
    }
  }

  function armed() { return Date.now() <= armedUntil }

  function disarm() {
    armedUntil = 0
    processArmed = false
    psTimer.stop()
  }

  function promote(bind, why) {
    disarm()
    lastEvent = why + " -> " + bind.combo
    toast.show(bind.combo, bind.description, bump(bind.combo))
  }

  Component.onCompleted: {
    bindsProc.running = true
    if (appSlice) launchWatch.running = true
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = String(event.name)
      var data = String(event.data)
      if (name === "configreloaded") { bindsProc.running = true; return }
      if (name === "closelayer") {
        if (service.launcherLayers.indexOf(data) !== -1) service.arm(service.window, "closed " + data, true)
        return
      }
      if (name === "openlayer") {
        // The menu reopened (submenu, launcher): wait for what it does next.
        if (data === "omarchy-menu") { service.disarm(); return }
        if (!service.armed()) return
        var layerHit = Promoter.matchLayer(service.binds, data)
        if (layerHit) service.promote(layerHit, "layer " + data)
        return
      }
      if (name === "openwindow" && service.armed()) {
        var parts = event.parse(4)
        var cls = parts.length > 2 ? parts[2] : ""
        var entry = cls ? DesktopEntries.heuristicLookup(cls) : null
        var hit = Promoter.matchWindow(service.binds, cls, entry)
        // The first window after arming is the one the shell launched, so it
        // consumes the arming either way. A keybinding pressed a few seconds
        // after launching some unbound app must never be mistaken for it.
        if (hit) service.promote(hit, "window " + cls)
        else { service.disarm(); service.lastEvent = "window " + cls + " (no binding)" }
      }
    }
  }

  // Scripts with no window of their own show up only in the process table.
  Timer {
    id: psTimer
    interval: 350
    repeat: true
    onTriggered: {
      if (!service.processArmed || !service.armed() || service.psRuns >= 4) { psTimer.stop(); return }
      service.psRuns++
      psProc.running = true
    }
  }

  // Prints "<etimes> <shell|-> <args>" for processes younger than 4s, where
  // "shell" means the process environment carries the shell marker.
  Process {
    id: psProc
    command: ["bash", "-c", [
      "ps -eo etimes=,pid=,args= | while read -r et pid args; do",
      "  [ \"$et\" -le 3 ] || continue",
      "  tag=-",
      "  if [ -n \"$1\" ] && grep -qsz \"^$1=\" \"/proc/$pid/environ\"; then tag=shell; fi",
      "  printf '%s %s %s\\n' \"$et\" \"$tag\" \"$args\"",
      "done"
    ].join("\n"), "key-promoter-ps", service.shellMarker]
    stdout: StdioCollector {
      onStreamFinished: {
        if (!service.processArmed || !service.armed()) return
        var hit = Promoter.matchProcesses(service.binds, text, 3, service.shellMarker !== "")
        if (hit) service.promote(hit, "process")
      }
    }
  }

  // New scope directories under the app slice, one name per line.
  Process {
    id: launchWatch
    command: ["inotifywait", "-m", "-q", "-e", "create", "--format", "%f", service.appSlice]
    onStarted: { service.launchWatchOk = true; service.launchWatchRetries = 0 }
    onExited: {
      service.launchWatchOk = false
      if (service.launchWatchRetries++ < 5) launchWatchRetry.restart()
      else console.warn("key-promoter: launch watcher gave up; dock launches won't be detected")
    }
    stdout: SplitParser {
      onRead: function(line) {
        if (Promoter.isLauncherScope(line)) service.arm(service.launchWindow, "shell app launch", false)
      }
    }
    stderr: StdioCollector { onStreamFinished: if (text.length) console.warn("key-promoter inotifywait:", text) }
  }

  Timer {
    id: launchWatchRetry
    interval: 5000
    onTriggered: launchWatch.running = true
  }

  Process {
    id: bindsProc
    command: ["bash", service.pluginDir + "/bin/keybinds"]
    stdout: StdioCollector { onStreamFinished: service.loadBinds(text) }
    stderr: StdioCollector { onStreamFinished: if (text.length) console.warn("key-promoter keybinds:", text) }
  }

  FileView {
    id: shellConfig
    path: service.home + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onLoaded: service.applySettings(text())
    onFileChanged: reload()
  }

  FileView {
    id: stateFile
    path: service.statePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: service.loadCounts(text())
  }

  Toast {
    id: toast
    shell: service.shell
    duration: service.duration
    position: service.position
    showCount: service.showCount
  }

  IpcHandler {
    target: "key-promoter"
    function ping(): string { return "ok" }
    function reload(): string { bindsProc.running = true; return "ok" }
    function show(combo: string, description: string): string { toast.show(combo, description, 0); return "ok" }
    function hide(): string { toast.hide(); return "ok" }
    function stats(): string { return JSON.stringify(service.counts) }
    function state(): string {
      return JSON.stringify({
        binds: service.binds.length,
        armed: service.armed(),
        launchWatch: service.launchWatchOk,
        shellMarker: service.shellMarker,
        duration: service.duration,
        lastEvent: service.lastEvent
      })
    }
    function resolved(): string {
      var out = []
      for (var i = 0; i < service.binds.length; i++) {
        var b = service.binds[i]
        if (b.sig && b.sig.kind !== "menu") out.push({ combo: b.combo, description: b.description, sig: b.sig })
      }
      return JSON.stringify(out)
    }
  }
}
