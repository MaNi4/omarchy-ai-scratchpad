.pragma library

// The settings: their defaults, how the config file is read and written, and
// the agents on offer. Pure, so it runs under node in tests/run.js.
// bin/ai-scratchpad reads the same file and keeps the same defaults.

// Omarchy's own launcher for the agent chosen as its default; with none
// chosen yet, --pick opens Omarchy's picker.
var OMARCHY = "omarchy agent --inline --pick"

var DEFAULTS = {
  hotkey: "SUPER + A",           // shows and hides the scratchpad; "" binds nothing
  moveHotkey: "SUPER + ALT + A", // sends the focused window to it; "" binds nothing
  settingsHotkey: "SUPER + CTRL + ALT + A", // opens these settings; "" binds nothing
  agent: OMARCHY,                // the command to run; may carry arguments
  folder: "~/Work",              // where it runs
  slide: "top",                  // "top", or "bottom" like the regular scratchpad
}

// Offered in this order; the ones that are installed come first.
var AGENTS = [
  { command: OMARCHY, name: "Omarchy default agent" },
  { command: "claude", name: "Claude Code" },
  { command: "codex", name: "Codex" },
  { command: "gemini", name: "Gemini CLI" },
  { command: "opencode", name: "OpenCode" },
  { command: "copilot", name: "GitHub Copilot" },
  { command: "cursor-agent", name: "Cursor Agent" },
  { command: "amp", name: "Amp" },
  { command: "aider", name: "Aider" },
  { command: "crush", name: "Crush" },
  { command: "goose", name: "Goose" },
  { command: "grok", name: "Grok" },
  { command: "hermes", name: "Hermes" },
  { command: "muse", name: "Muse Code" },
  { command: "omp", name: "Oh My Pi" },
  { command: "openclaw", name: "OpenClaw" },
  { command: "pi", name: "Pi" },
  { command: "qwen", name: "Qwen Code" },
]

// The file's text -> every setting, with defaults for what is missing or of
// the wrong type. `error` is set when the text is not a JSON object.
function parse(text) {
  var raw = null
  var error = ""
  if (String(text || "").trim() !== "") {
    try { raw = JSON.parse(text) } catch (e) { error = String(e) }
    if (!error && (raw === null || typeof raw !== "object" || Array.isArray(raw))) error = "not a JSON object"
  }
  var config = {}
  for (var name in DEFAULTS) {
    var value = raw && !error ? raw[name] : undefined
    config[name] = typeof value === "string" ? value.trim() : DEFAULTS[name]
  }
  if (config.agent === "") config.agent = DEFAULTS.agent
  if (config.folder === "") config.folder = DEFAULTS.folder
  if (config.slide !== "bottom") config.slide = "top"
  return { config: config, error: error }
}

// The file's text with `changes` applied. Keys we do not know are kept.
function update(text, changes) {
  var raw = {}
  try { raw = JSON.parse(text) } catch (e) { raw = {} }
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) raw = {}
  var config = parse(JSON.stringify(raw)).config
  for (var name in DEFAULTS) raw[name] = changes && typeof changes[name] === "string" ? changes[name] : config[name]
  return JSON.stringify(raw, null, 2) + "\n"
}

function agent(command) {
  if (String(command || "").trim() === OMARCHY) return AGENTS[0]
  var program = String(command || "").trim().split(/\s+/)[0]
  for (var i = 0; i < AGENTS.length; i++) if (AGENTS[i].command === program) return AGENTS[i]
  return null
}

// "omarchy agent --inline" -> "omarchy": what has to be installed for it.
function program(command) {
  return String(command || "").trim().split(/\s+/)[0]
}

// "claude --continue" -> "Claude Code"; an agent we do not know keeps its command.
function agentName(command) {
  var known = agent(command)
  return known ? known.name : String(command || "").trim()
}

// The agents to choose from for what is typed so far. `installed` is the list
// of commands found on this machine, or null while that is not known yet.
//   [{ command: "claude", name: "Claude Code", off: false, on: true }]
function agentChoices(installed, typed, current) {
  var query = String(typed || "").trim()
  var needle = query.toLowerCase()
  var has = function(command) { return !installed || installed.indexOf(program(command)) >= 0 }
  var here = []
  var missing = []
  var exact = false
  for (var i = 0; i < AGENTS.length; i++) {
    var known = AGENTS[i]
    if (known.command === query) exact = true
    if (needle && known.command.indexOf(needle) < 0 && known.name.toLowerCase().indexOf(needle) < 0) continue
    ;(has(known.command) ? here : missing).push({ command: known.command, name: known.name, off: !has(known.command), on: known.command === current })
  }
  var own = []
  // A command of your own: what is typed, or the one in use now.
  if (query && !exact) own.push({ command: query, name: query, off: false, on: query === current, custom: true })
  else if (!query && current && (!agent(current) || agent(current).command !== current))
    own.push({ command: current, name: current, off: false, on: true, custom: true })
  return own.concat(here, missing)
}

// "/home/me/Projects" -> "~/Projects"
function shortPath(path, home) {
  var text = String(path || "")
  if (home && (text === home || text.indexOf(home + "/") === 0)) return "~" + text.substring(home.length)
  return text
}
