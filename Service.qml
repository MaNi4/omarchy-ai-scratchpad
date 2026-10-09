import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "Config.js" as Config
import "Hotkey.js" as Hotkey

// Sets the scratchpad up in the running Hyprland session: the keys, and what
// starts when it is opened empty (bin/ai-scratchpad). A service is mounted
// with the shell, so the keys work without anything having been opened.
Item {
  id: service
  visible: false

  readonly property string pluginId: "mani4.ai-scratchpad"
  readonly property string workspace: "ai"
  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/extensions/ai-scratchpad.json"
  readonly property string pluginDir: {
    var s = String(Qt.resolvedUrl("."))
    return s.indexOf("file://") === 0 ? s.substring(7) : s
  }

  property var config: Config.parse("").config
  property bool firstRun: false       // there was no config file: say hello, once
  property var boundHotkeys: []       // what we bound, so unloading can unbind it
  property var warned: ({})           // notify once per taken key, not on every reload
  property bool queued: false

  function applyConfig(text, missing) {
    var parsed = Config.parse(text)
    // Nothing of the file's text goes to the log.
    if (parsed.error) console.warn("ai-scratchpad: " + service.configPath + " is not a JSON object, the defaults are used")
    service.config = parsed.config
    service.firstRun = missing
    startTimer.restart()
  }

  FileView {
    path: service.configPath
    watchChanges: true
    printErrors: false
    onLoaded: { service.secure(); service.applyConfig(text(), false) }
    onLoadFailed: service.applyConfig("", true)
    onFileChanged: reload()
  }

  // The agent's command may hold a key, as in KEY=... agent: the config is
  // for its owner alone. A file from an earlier version, or one made or
  // replaced by hand, is closed to others here each time it is loaded;
  // Settings.qml keeps it so when it saves.
  function secure() {
    Quickshell.execDetached(["sh", "-c", 'case "$(stat -L -c %a "$1" 2>/dev/null)" in ""|?00) ;; *) chmod go-rwx "$1" ;; esac', "sh", service.configPath])
  }

  // The short delay lets a previous instance's unbind land first when the
  // plugin is reloaded.
  Timer {
    id: startTimer
    interval: 600
    onTriggered: service.ensure()
  }

  function ensure() {
    if (animationsProc.running || bindsProc.running) { service.queued = true; return }
    animationsProc.running = true
  }

  function evaluate(lua) {
    Quickshell.execDetached(["hyprctl", "eval", lua])
  }

  // One leaf of `hyprctl animations -j` as Lua, with another style or its own.
  function slide(leaf, style) {
    return "hl.animation({ leaf = " + Hotkey.quote(leaf.name) + ", enabled = true, speed = " + Number(leaf.speed)
      + ", bezier = " + Hotkey.quote(leaf.bezier) + (style ? ", style = " + Hotkey.quote(style) : "") + " })"
  }

  // Hyprland ignores per-workspace animation styles on special workspaces, so
  // the key sets the slide direction, toggles, and puts the configured one
  // back at once: the slide that has started keeps its direction, and the
  // regular scratchpad never sees ours. prepare() defines the function.
  readonly property string toggleAction: "function() if _G.ai_scratchpad_toggle then _G.ai_scratchpad_toggle() else "
    + service.toggleDispatch + " end end"
  readonly property string toggleDispatch: "hl.dispatch(hl.dsp.workspace.toggle_special(" + Hotkey.quote(service.workspace) + "))"
  readonly property string moveAction: "hl.dsp.window.move({ workspace = " + Hotkey.quote("special:" + service.workspace) + ", follow = false })"

  readonly property string settingsAction: "hl.dsp.exec_cmd(" + Hotkey.quote("omarchy-shell shell toggle " + service.pluginId + " '{}'") + ")"

  // Everything but the keys. Hyprland forgets all of it when its config reloads.
  function prepare(animationsJson) {
    // The slide in and the slide out of special workspaces, each as it is
    // configured: what the key puts back is exactly what it found. A leaf
    // that is not set by itself takes after "specialWorkspace".
    var parent = null
    var into = null
    var out = null
    try {
      var leaves = JSON.parse(animationsJson)[0] || []
      for (var i = 0; i < leaves.length; i++) {
        if (leaves[i].name === "specialWorkspace") parent = leaves[i]
        else if (leaves[i].name === "specialWorkspaceIn") into = leaves[i]
        else if (leaves[i].name === "specialWorkspaceOut") out = leaves[i]
      }
    } catch (e) {}
    var own = function(leaf) {
      if (!leaf) return null
      var from = leaf.overridden || !parent ? leaf : parent
      var usable = from.enabled && from.bezier && isFinite(Number(from.speed))
      return usable ? { name: leaf.name, speed: from.speed, bezier: from.bezier, style: String(from.style || "") } : null
    }
    into = own(into)
    out = own(out)

    var fromTop = service.config.slide === "top" && into !== null && out !== null
    var lua = [
      // The settings appear at once, like Omarchy's own menu, not with the layer animation.
      'hl.layer_rule({ match = { namespace = "^omarchy-ai-scratchpad$" }, no_anim = true, animation = "none" })',
      "hl.workspace_rule({ workspace = " + Hotkey.quote("special:" + service.workspace)
        + ", on_created_empty = " + Hotkey.quote(service.pluginDir + "bin/ai-scratchpad") + " })",
      fromTop
        ? "_G.ai_scratchpad_toggle = function() " + service.slide(into, "slidevert top") + " " + service.slide(out, "slidevert bottom")
          + " " + service.toggleDispatch + " " + service.slide(into, into.style) + " " + service.slide(out, out.style) + " end"
        : "_G.ai_scratchpad_toggle = nil",
    ]
    service.evaluate(lua.join("\n"))
  }

  function reconcile(bindsJson) {
    var plan = Hotkey.plan(bindsJson, [
      { setting: "hotkey", hotkey: service.config.hotkey, description: Hotkey.TOGGLE, action: service.toggleAction },
      { setting: "moveHotkey", hotkey: service.config.moveHotkey, description: Hotkey.MOVE, action: service.moveAction },
      { setting: "settingsHotkey", hotkey: service.config.settingsHotkey, description: Hotkey.SETTINGS, action: service.settingsAction },
    ])
    if (plan.lua.length > 0) service.evaluate(plan.lua.join("\n"))
    service.boundHotkeys = plan.bound

    var conflict = Hotkey.notice(plan.conflicts, service.warned)
    if (conflict && !note.running) {
      for (var i = 0; i < conflict.hotkeys.length; i++) service.warned[conflict.hotkeys[i]] = true
      note.show(conflict.title, conflict.body, conflict.action, conflict.payload)
    } else if (service.firstRun && plan.conflicts.length === 0 && !note.running) {
      var key = Hotkey.tidy(service.config.hotkey)
      var settingsKey = Hotkey.tidy(service.config.settingsHotkey)
      note.show("AI Scratchpad",
        (key ? key + " opens your AI agent. " : "No key opens the AI scratchpad yet. ")
        + (settingsKey ? settingsKey + " or a click here changes" : "Click to change") + " the agent, the folder and the keys.", "Settings", "{}")
    }
    // Hello is said once: from now on there is a config file, ready to edit.
    if (service.firstRun && !conflict) {
      service.firstRun = false
      creator.running = true
    }
    if (service.queued) { service.queued = false; service.ensure() }
  }

  // The first config file: made for its owner alone (see secure()), and its
  // text sent over stdin like every later save, never as an argument.
  Process {
    id: creator
    // noclobber: a file that appeared meanwhile is never written over.
    command: ["sh", "-c", 'umask 077; set -C; mkdir -p "$(dirname "$1")" && cat > "$1" 2>/dev/null || cat > /dev/null', "sh", service.configPath]
    stdinEnabled: true
    onStarted: {
      write(Config.update("", service.config))
      stdinEnabled = false
    }
    onExited: stdinEnabled = true
  }

  // Clicking the notification opens the settings (Settings.qml).
  Process {
    id: note
    property string payload: "{}"
    function show(title, body, action, payloadJson) {
      note.payload = payloadJson
      note.command = ["notify-send", "-a", "AI Scratchpad", "-A", "default=" + action, title, body]
      note.running = true
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (String(text || "").trim() === "default")
          Quickshell.execDetached(["omarchy-shell", "shell", "summon", service.pluginId, note.payload])
      }
    }
  }

  Process {
    id: animationsProc
    command: ["hyprctl", "animations", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        service.prepare(String(text || ""))
        bindsProc.running = true
      }
    }
  }

  Process {
    id: bindsProc
    command: ["hyprctl", "binds", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.reconcile(String(text || ""))
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event) return
      var name = String(event.name)
      // Hyprland drops runtime binds and rules when its config reloads.
      if (name === "configreloaded") {
        service.ensure()
      }
    }
  }

  // Disabling, removing or reloading the plugin takes the keys with it.
  Component.onDestruction: {
    var lua = []
    for (var i = 0; i < service.boundHotkeys.length; i++) {
      var combo = Hotkey.parse(service.boundHotkeys[i])
      if (combo) lua.push(Hotkey.unbind(combo.mask, combo.key))
    }
    lua.push("_G.ai_scratchpad_toggle = nil")
    if (lua.length > 0) Quickshell.execDetached(["hyprctl", "eval", lua.join("\n")])
  }
}
