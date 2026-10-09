.pragma library

// The keys of the scratchpad: which Lua to hand `hyprctl eval` so that each
// action is bound to its configured key and to no other, and which keys to
// offer when one is taken. Pure: `hyprctl binds -j` in, answers out, so it
// runs under node in tests/run.js.
//
// Our bindings are told apart by their description. No config file is
// written here; Hyprland forgets runtime binds when its config reloads, so
// Service.qml asks again after every reload.

var TOGGLE = "Toggle AI scratchpad"
var MOVE = "Move window to AI scratchpad"
var SETTINGS = "AI scratchpad settings"

// Offered when a key is taken, in this order, by the setting they are for.
var IDEAS = {
  hotkey: ["SUPER + A", "SUPER + CTRL + A", "SUPER + SHIFT + A", "SUPER + I", "SUPER + ALT + I",
    "SUPER + GRAVE", "SUPER + SEMICOLON", "SUPER + APOSTROPHE", "SUPER + BACKSLASH", "ALT + A"],
  moveHotkey: ["SUPER + ALT + A", "SUPER + ALT + SHIFT + A", "SUPER + ALT + I",
    "SUPER + CTRL + I", "SUPER + ALT + GRAVE", "SUPER + ALT + SEMICOLON", "SUPER + ALT + BACKSLASH"],
  settingsHotkey: ["SUPER + CTRL + ALT + A", "SUPER + CTRL + SHIFT + A", "SUPER + CTRL + ALT + I", "SUPER + CTRL + GRAVE",
    "SUPER + CTRL + SEMICOLON", "SUPER + CTRL + BACKSLASH", "CTRL + ALT + A"],
}

var MODIFIERS = { SHIFT: 1, CTRL: 4, CONTROL: 4, ALT: 8, SUPER: 64 }
var ORDER = [["SUPER", 64], ["CTRL", 4], ["ALT", 8], ["SHIFT", 1]]

// "SUPER + ALT + A" -> { mask: 72, key: "A" }; null when empty or malformed.
function parse(text) {
  var parts = String(text || "").split("+").map(function(part) { return part.trim().toUpperCase() })
  var key = parts.pop()
  if (!key || !/^[A-Z0-9_:]+$/.test(key) || MODIFIERS[key] !== undefined) return null
  var mask = 0
  for (var i = 0; i < parts.length; i++) {
    if (MODIFIERS[parts[i]] === undefined) return null
    mask |= MODIFIERS[parts[i]]
  }
  return { mask: mask, key: key }
}

function format(mask, key) {
  var names = []
  for (var i = 0; i < ORDER.length; i++) if (mask & ORDER[i][1]) names.push(ORDER[i][0])
  names.push(key)
  return names.join(" + ")
}

// "super+alt + a" -> "SUPER + ALT + A"; "" when it is not a key combination.
function tidy(text) {
  var combo = parse(text)
  return combo ? format(combo.mask, combo.key) : ""
}

function read(bindsJson) {
  var binds = []
  try { binds = JSON.parse(bindsJson) || [] } catch (e) { binds = [] }
  return binds
}

function name(bind) {
  return bind.description || bind.dispatcher || "another binding"
}

// What already runs on that key, "" when it is free. The binding with
// `description`, the one the key is being chosen for, does not count.
function holder(bindsJson, hotkey, description) {
  var binds = read(bindsJson)
  var want = parse(hotkey)
  if (!want) return ""
  for (var i = 0; i < binds.length; i++) {
    var bind = binds[i]
    if (bind.description === description) continue
    if (bind.modmask === want.mask && keyOf(bind) === want.key) return name(bind)
  }
  return ""
}

// The keys to choose from for what is typed so far: the typed combination
// itself when it reads as one, then the ideas it matches. Free keys come
// first; a taken one says what holds it.
//   [{ hotkey: "SUPER + A", holder: "" }, { hotkey: "SUPER + K", holder: "Keybindings" }]
function choices(bindsJson, typed, ideas, description) {
  // A bare letter is not a key to give away to a scratchpad.
  var combo = parse(typed)
  var own = combo && combo.mask !== 0 ? format(combo.mask, combo.key) : ""
  var query = String(typed || "").toUpperCase().replace(/\s+/g, "")
  var hotkeys = own ? [own] : []
  for (var i = 0; i < ideas.length; i++) {
    if (ideas[i] !== own && ideas[i].replace(/\s+/g, "").indexOf(query) >= 0) hotkeys.push(ideas[i])
  }
  var free = []
  var taken = []
  for (var j = 0; j < hotkeys.length; j++) {
    var held = holder(bindsJson, hotkeys[j], description)
    ;(held ? taken : free).push({ hotkey: hotkeys[j], holder: held })
  }
  return free.concat(taken)
}

function quote(text) {
  return '"' + String(text).replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n") + '"'
}

function keyOf(bind) {
  // Keycode binds ("code:58") report the key in `keycode`.
  return bind.key ? String(bind.key).toUpperCase() : (bind.keycode ? "CODE:" + bind.keycode : "")
}

function unbind(mask, key) {
  return "hl.unbind(" + quote(format(mask, key)) + ")"
}

// wanted: [{ setting: "hotkey", hotkey: "SUPER + A", description: TOGGLE, action: "<Lua>" }]
// Returns { lua: [statements], bound: [hotkeys we hold], conflicts: [{ setting, hotkey, holder }] }.
// A key somebody else holds is never taken over; it comes back as a conflict.
function plan(bindsJson, wanted) {
  var binds = read(bindsJson)
  var unbinds = []   // all of them go first: one of ours may leave a key another of ours takes
  var newBinds = []
  var bound = []
  var conflicts = []
  // Without a prototype: a binding described "constructor" is not one of ours.
  var ours = Object.create(null)
  var claimed = Object.create(null)   // hotkey -> the description that has it after this plan
  for (var w = 0; w < wanted.length; w++) ours[wanted[w].description] = true

  for (var n = 0; n < wanted.length; n++) {
    var item = wanted[n]
    var want = parse(item.hotkey)
    var have = false
    for (var i = 0; i < binds.length; i++) {
      var bind = binds[i]
      if (bind.description !== item.description) continue
      if (want && bind.modmask === want.mask && keyOf(bind) === want.key && !claimed[format(want.mask, want.key)]) have = true
      else unbinds.push(unbind(bind.modmask, keyOf(bind)))
    }
    if (!want) continue
    var hotkey = format(want.mask, want.key)
    var held = claimed[hotkey] || ""
    for (var j = 0; j < binds.length && !held && !have; j++) {
      var other = binds[j]
      // One of ours is not in the way: it stays only if `claimed` says so.
      if (ours[other.description]) continue
      if (other.modmask === want.mask && keyOf(other) === want.key) held = name(other)
    }
    if (held) { conflicts.push({ setting: item.setting, hotkey: hotkey, holder: held }); continue }

    claimed[hotkey] = item.description
    bound.push(hotkey)
    if (!have) newBinds.push("hl.bind(" + quote(hotkey) + ", " + item.action + ", { description = " + quote(item.description) + " })")
  }
  return { lua: unbinds.concat(newBinds), bound: bound, conflicts: conflicts }
}

// What to tell about the keys that are taken, null when there is nothing new:
// one notification for all of them, not one after another. `warned` holds
// the keys already told about. A single key opens its own picker.
//   { title, body, action, payload, hotkeys: [the keys this tells about] }
function notice(conflicts, warned) {
  var fresh = conflicts.filter(function(taken) { return !warned[taken.hotkey] })
  if (fresh.length === 0) return null
  var lines = fresh.map(function(taken) { return taken.hotkey + " is already in use." })
  var hotkeys = fresh.map(function(taken) { return taken.hotkey })
  if (fresh.length === 1)
    return { title: "AI Scratchpad: " + fresh[0].hotkey + " is taken", body: lines[0] + " Click to choose another one.",
             action: "Choose a key", payload: JSON.stringify({ setup: fresh[0].setting }), hotkeys: hotkeys }
  return { title: "AI Scratchpad: " + fresh.length + " shortcuts are taken", body: lines.join("\n") + "\nClick to choose others.",
           action: "Choose keys", payload: "{}", hotkeys: hotkeys }
}
