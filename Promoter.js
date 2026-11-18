.pragma library

// Pure logic for the Key Promoter: turning binds into launch signatures,
// matching those against what just happened, and formatting key combos.
// No QML state lives here, so every function can be tested from plain JS.
//
// Based on Forrest Knight's omarchy-key-promoter (MIT), updated for
// Hyprland's Lua config (dispatcher "lua" binds) and resolved default browsers.

function basename(path) {
  var p = String(path || "")
  var i = p.lastIndexOf("/")
  return i >= 0 ? p.slice(i + 1) : p
}

// Minimal shell tokenizer: whitespace-separated, honoring '...' and "...".
function shellSplit(input) {
  var out = []
  var cur = ""
  var quote = ""
  var has = false
  var s = String(input || "")
  for (var i = 0; i < s.length; i++) {
    var ch = s[i]
    if (quote) {
      if (ch === quote) quote = ""
      else cur += ch
    } else if (ch === "'" || ch === '"') {
      quote = ch
      has = true
    } else if (ch === " " || ch === "\t") {
      if (has || cur.length) { out.push(cur); cur = ""; has = false }
    } else {
      cur += ch
    }
  }
  if (has || cur.length) out.push(cur)
  return out
}

// Drop launcher wrappers so "uwsm-app -- chromium" and "chromium" agree.
function stripWrappers(tokens) {
  var t = tokens.slice()
  while (t.length) {
    var head = basename(t[0])
    if ((head === "uwsm-app" || head === "setsid") && t[1] === "--") { t.splice(0, 2); continue }
    if (head === "uwsm" && t[1] === "app" && t[2] === "--") { t.splice(0, 3); continue }
    if (head === "uwsm-app" || head === "setsid" || head === "exec" || head === "nohup") { t.splice(0, 1); continue }
    if (head === "bash" || head === "sh" || head === "env") { t.splice(0, 1); continue }
    break
  }
  return t
}

function lowerList(list) {
  var out = []
  for (var i = 0; i < list.length; i++) {
    var v = String(list[i] || "").toLowerCase()
    if (v && out.indexOf(v) === -1) out.push(v)
  }
  return out
}

function appSig(values, cmd) {
  var v = lowerList(values)
  return v.length ? { kind: "app", values: v, cmd: cmd } : null
}

function webappSignature(url, cmd) {
  var u = String(url || "").replace(/^[a-z]+:\/\//i, "")
  var slash = u.indexOf("/")
  var host = (slash >= 0 ? u.slice(0, slash) : u).toLowerCase()
  var path = slash >= 0 ? u.slice(slash + 1) : ""
  path = path.replace(/[?#].*$/, "").replace(/\/+$/, "")
  // Chromium-family app windows are named "<browser>-<host>__<path with / as _>-Default".
  return { kind: "webapp", host: host, path: path.replace(/\//g, "_").toLowerCase(), cmd: cmd }
}

// Shell plugin id ("omarchy.clipboard") -> its layer namespace prefix ("omarchy-clipboard").
function layerFor(pluginId) {
  return String(pluginId || "").replace(".", "-").toLowerCase()
}

function signatureForCommand(command, defaults) {
  var tokens = stripWrappers(shellSplit(command))
  if (!tokens.length) return null
  var t0 = basename(tokens[0])
  var d = defaults || {}

  if (t0 === "omarchy-launch-webapp") return webappSignature(tokens[1], t0)
  if (t0 === "omarchy-launch-or-focus-webapp") return webappSignature(tokens[2], t0)
  if (t0 === "omarchy-launch-tui" || t0 === "omarchy-launch-or-focus-tui") {
    var rest = tokens.slice(1)
    var appId = ""
    if (rest.length && rest[0].indexOf("--app-id=") === 0) { appId = rest[0].slice(9); rest = rest.slice(1) }
    if (!appId && rest.length) appId = "org.omarchy." + basename(rest[0])
    return appId ? { kind: "tui", value: appId.toLowerCase(), cmd: t0 } : null
  }
  if (t0 === "omarchy-launch-or-focus") {
    var inner = tokens.length > 2 ? signatureForCommand(tokens.slice(2).join(" "), d) : null
    return inner || appSig([String(tokens[1] || "").replace(/^\^|\$$/g, "")], t0)
  }
  if (t0 === "omarchy-launch-browser") {
    // A private window is still the browser; promote the plain binding first
    // (pick() prefers fewer modifiers).
    return appSig(Array.isArray(d.browser) ? d.browser : [d.browser], t0)
  }
  if (t0 === "omarchy-launch-editor") return appSig(Array.isArray(d.editor) ? d.editor : [d.editor], t0)
  if (t0 === "omarchy-launch-nautilus" || t0 === "omarchy-launch-nautilus-cwd") return appSig(["org.gnome.nautilus", "nautilus"], t0)
  if (t0 === "omarchy-launch-terminal") return { kind: "cmd", cmd: t0 }
  if (t0.indexOf("omarchy-menu") === 0) return { kind: "menu", cmd: t0 }
  if (t0 === "omarchy-shell") {
    for (var i = 1; i < tokens.length; i++) {
      if (/^[a-z0-9_-]+\.[a-z0-9_-]+$/i.test(tokens[i])) return { kind: "layer", value: layerFor(tokens[i]), cmd: t0 }
    }
    return null
  }
  // omarchy-launch-spotify, -signal, -1password...: a script that opens a
  // window named after the app, so match either the script or the window.
  if (t0.indexOf("omarchy-launch-") === 0) return { kind: "cmd", cmd: t0, values: lowerList([t0.slice(15)]) }
  if (t0.indexOf("omarchy-") === 0) return { kind: "cmd", cmd: t0 }
  return appSig([t0], t0)
}

// Lua binds, e.g. hl.dsp.global("omarchy:panel.omarchy.clipboard").
function signatureForLua(expr) {
  var m = /global\(\s*["']omarchy:([^"']+)["']\s*\)/.exec(String(expr || ""))
  if (!m) return null
  var route = m[1]
  if (route.indexOf("menu.") === 0) return { kind: "menu", cmd: route }
  if (route.indexOf("panel.") === 0) return { kind: "layer", value: layerFor(route.slice(6)), cmd: route }
  return null
}

function signature(bind, defaults) {
  if (!bind) return null
  if (bind.dispatcher === "exec") return signatureForCommand(bind.arg, defaults)
  if (bind.dispatcher === "lua") return signatureForLua(bind.arg)
  return null
}

// "SUPER SHIFT + Q / XF86Calculator" -> "SUPER SHIFT + Q": the menu joins
// alternative chords on one row; the first one is the one to teach.
function primaryCombo(combo) {
  return String(combo || "").split(" / ")[0].replace(/\s+$/, "")
}

// Decorate raw exporter output with signatures and a modifier count.
function prepare(payload) {
  var data = payload || {}
  var binds = Array.isArray(data.binds) ? data.binds : []
  var out = []
  for (var i = 0; i < binds.length; i++) {
    var b = binds[i]
    var combo = primaryCombo(b.combo)
    var media = isMediaKey(combo)
    out.push({
      combo: combo,
      description: String(b.description || ""),
      dispatcher: String(b.dispatcher || ""),
      arg: String(b.arg || ""),
      mods: modCount(combo),
      // Media keys (XF86Calculator, XF86Mail...) are labeled hardware buttons,
      // not shortcuts worth teaching. Never promote them.
      media: media,
      sig: media ? null : signature(b, data.defaults)
    })
  }
  return out
}

function isMediaKey(combo) {
  var parts = String(combo || "").split(" + ")
  return /^XF86/i.test(parts[parts.length - 1] || "")
}

function modCount(combo) {
  var parts = String(combo || "").split(" + ")
  if (parts.length < 2) return 0
  return parts[0].split(/\s+/).filter(function(p) { return p.length }).length
}

// Among several binds that do the same thing, promote the cheapest one.
function pick(candidates) {
  var best = null
  for (var i = 0; i < candidates.length; i++) {
    var c = candidates[i]
    if (!best
        || c.score > best.score
        || (c.score === best.score && c.bind.mods < best.bind.mods)
        || (c.score === best.score && c.bind.mods === best.bind.mods && c.bind.combo.length < best.bind.combo.length)) {
      best = c
    }
  }
  return best ? best.bind : null
}

// A window with class `cls` appeared. `entry` is the DesktopEntry Quickshell
// resolved for it (may be null); its command and id catch apps whose binary
// name differs from the window class.
function matchWindow(binds, cls, entry) {
  var c = String(cls || "").toLowerCase()
  if (!c) return null
  var entryId = ""
  var entryCmd = ""
  if (entry) {
    entryId = basename(entry.id || "").toLowerCase().replace(/\.desktop$/, "")
    var cmd = entry.command && entry.command.length ? entry.command[0] : (entry.execString ? shellSplit(entry.execString)[0] : "")
    entryCmd = basename(cmd || "").toLowerCase()
  }
  // Chromium-family app-mode class: chrome-<host>__<path>-Default
  var web = /^(?:chrome|chromium|brave-origin|brave-browser|brave|msedge|vivaldi|helium)-(.+?)__(.*?)-default$/i.exec(c)

  var found = []
  for (var i = 0; i < binds.length; i++) {
    var s = binds[i].sig
    if (!s) continue
    var score = 0
    if (s.values && (s.kind === "app" || s.kind === "cmd")) {
      if (s.values.indexOf(c) !== -1) score = 20
      else if (entryCmd && s.values.indexOf(entryCmd) !== -1) score = 15
      else if (entryId && s.values.indexOf(entryId) !== -1) score = 12
    } else if (s.kind === "tui") {
      if (s.value === c) score = 25
    } else if (s.kind === "webapp" && web) {
      if (web[1].toLowerCase() === s.host) score = (web[2].toLowerCase() === s.path) ? 30 : 8
    }
    if (score) found.push({ score: score, bind: binds[i] })
  }
  return pick(found)
}

// A shell layer (emoji picker, clipboard manager, app grid...) opened.
// Namespaces can carry a suffix ("omarchy-dock-apps" for omarchy.dock).
function matchLayer(binds, namespace) {
  var ns = String(namespace || "").toLowerCase()
  if (!ns) return null
  var found = []
  for (var i = 0; i < binds.length; i++) {
    var s = binds[i].sig
    if (!s || s.kind !== "layer") continue
    if (s.value === ns) found.push({ score: 2, bind: binds[i] })
    else if (ns.indexOf(s.value + "-") === 0) found.push({ score: 1, bind: binds[i] })
  }
  return pick(found)
}

// Name of a systemd unit uwsm created for `uwsm-app -- gtk-launch ...`, which
// is how the shell's app list, launcher grid and dock start apps (and no
// keybinding does). systemd escapes the hyphen: app-Hyprland-gtk\x2dlaunch-0b3dedd1.scope
function isLauncherScope(unitName) {
  return /gtk(\\x2d|-)launch/i.test(String(unitName || ""))
}

// Process scan lines "<etimes> <tag> <args>": young omarchy-* scripts
// (screenshots, the color picker, lock...) that have no window or layer of
// their own. With `shellOnly`, only processes tagged "shell" count, i.e.
// those whose environment shows the shell (not a keybinding) started them.
function matchProcesses(binds, psOutput, maxAgeSeconds, shellOnly) {
  var lines = String(psOutput || "").split("\n")
  var young = {}
  for (var i = 0; i < lines.length; i++) {
    var m = /^\s*(\d+)\s+(\S+)\s+(.*)$/.exec(lines[i])
    if (!m) continue
    if (parseInt(m[1], 10) > maxAgeSeconds) continue
    if (shellOnly && m[2] !== "shell") continue
    var tokens = stripWrappers(shellSplit(m[3]))
    for (var t = 0; t < tokens.length && t < 3; t++) {
      var name = basename(tokens[t])
      if (name.indexOf("omarchy-") === 0) { young[name] = true; break }
    }
  }
  var found = []
  for (var b = 0; b < binds.length; b++) {
    var s = binds[b].sig
    if (s && s.kind === "cmd" && young[s.cmd]) found.push({ score: 1, bind: binds[b] })
  }
  return pick(found)
}

// "SUPER SHIFT + B" -> ["SUPER", "SHIFT", "B"]
function chips(combo) {
  var parts = String(combo || "").split(" + ")
  var out = []
  if (parts.length >= 2) {
    var mods = parts[0].split(/\s+/)
    for (var i = 0; i < mods.length; i++) if (mods[i]) out.push(mods[i])
    out.push(parts.slice(1).join(" + "))
  } else if (parts[0]) {
    out.push(parts[0])
  }
  return out
}
