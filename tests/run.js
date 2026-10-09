// node tests/run.js — checks Config.js, Hotkey.js and bin/ai-scratchpad; the QML is checked by hand.
const fs = require("fs")
const os = require("os")
const path = require("path")
const assert = require("assert")
const { spawnSync } = require("child_process")

const library = (file, names) => {
  const source = fs.readFileSync(path.join(__dirname, "..", file), "utf8").replace(/^\.pragma library\s*$/m, "")
  return new Function(source + "\nreturn { " + names + " }")()
}
const Config = library("Config.js", "parse, update, agentName, agentChoices, program, shortPath, DEFAULTS, AGENTS, OMARCHY")
const Hotkey = library("Hotkey.js", "parse, format, tidy, holder, plan, choices, notice, IDEAS, TOGGLE, MOVE, SETTINGS")

// What `hyprctl binds -j` reports: SUPER is 64, ALT 8, SHIFT 1.
const bind = (modmask, key, description) => ({ modmask, key, description, dispatcher: "exec" })
const binds = extra => JSON.stringify([bind(64, "K", "Keybindings"), bind(65, "M", "Music")].concat(extra || []))
const wanted = (hotkey, moveHotkey) => [
  { setting: "hotkey", hotkey, description: Hotkey.TOGGLE, action: "toggle()" },
  { setting: "moveHotkey", hotkey: moveHotkey, description: Hotkey.MOVE, action: "move()" },
]

// bin/ai-scratchpad with a hyprctl of our own: it reports one agent terminal
// in the scratchpad, a browser moved there, and an agent terminal elsewhere,
// and writes what it is asked to dispatch to `log`. `stuck` terminals stay.
const launcher = (argument, stuck) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ai-scratchpad-"))
  const log = path.join(dir, "log")
  const clients = JSON.stringify([
    { address: "0xa1", class: "org.omarchy.ai", workspace: { name: "special:ai" } },
    { address: "0xb2", class: "zen", workspace: { name: "special:ai" } },
    { address: "0xc3", class: "org.omarchy.ai", workspace: { name: "2" } },
  ])
  fs.writeFileSync(path.join(dir, "hyprctl"), `#!/bin/bash
if [[ $1 == clients ]]; then
  if [[ -z "${stuck ? 1 : ""}" ]] && grep -q window.close "${log}" 2>/dev/null; then echo "[]"; else echo '${clients}'; fi
else
  echo "$*" >> "${log}"
fi
`, { mode: 0o755 })
  fs.writeFileSync(path.join(dir, "notify-send"), `#!/bin/bash\necho "notify $*" >> "${log}"\n`, { mode: 0o755 })
  const run = spawnSync(path.join(__dirname, "..", "bin", "ai-scratchpad"), [argument],
    { env: Object.assign({}, process.env, { PATH: dir + ":" + process.env.PATH }), encoding: "utf8" })
  const lines = fs.existsSync(log) ? fs.readFileSync(log, "utf8").trim().split("\n") : []
  fs.rmSync(dir, { recursive: true })
  return { status: run.status, out: run.stdout.trim(), lines }
}

const tests = {
  // Folder names come from disk and bind descriptions from other configs; as rich text an <img> in one would be fetched.
  "every label is drawn as plain text"() {
    const lines = fs.readFileSync(path.join(__dirname, "..", "Settings.qml"), "utf8").split("\n")
    lines.forEach((line, at) => {
      if (/^\s*Text \{$/.test(line)) assert.match(lines[at + 1], /textFormat: Text\.PlainText/, "line " + (at + 1))
    })
  },
  // The agent's command may hold a key: the config is made and kept for its owner alone.
  "the config file is written for its owner alone"() {
    const write = (file, pattern, existing) => {
      const source = fs.readFileSync(path.join(__dirname, "..", file), "utf8")
      const script = source.match(pattern)
      assert.ok(script, file)
      const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ai-scratchpad-"))
      const config = path.join(dir, "extensions", "ai-scratchpad.json")
      if (existing) { fs.mkdirSync(path.dirname(config)); fs.writeFileSync(config, "{}", { mode: 0o644 }); fs.chmodSync(config, 0o644) }
      const run = spawnSync("sh", ["-c", "umask 022; " + script[1], "sh", config, "text"], { input: "text", encoding: "utf8" })
      const mode = fs.existsSync(config) ? (fs.statSync(config).mode & 0o777).toString(8) : ""
      const text = fs.existsSync(config) ? fs.readFileSync(config, "utf8") : ""
      fs.rmSync(dir, { recursive: true })
      return { mode, text, status: run.status }
    }
    const create = /'(umask 077; set -C; mkdir -p [^']*)'/
    const save = /'(umask 077; mkdir -p [^']* cat > "\$1")'/
    const close = /'(case "\$\(stat [^']*esac)'/
    assert.deepStrictEqual(write("Service.qml", create, false), { mode: "600", text: "text", status: 0 })
    assert.deepStrictEqual(write("Settings.qml", save, false), { mode: "600", text: "text", status: 0 })
    assert.deepStrictEqual(write("Settings.qml", save, true), { mode: "600", text: "text", status: 0 })
    assert.deepStrictEqual(write("Service.qml", close, true), { mode: "600", text: "{}", status: 0 })
    // A file that is there is left as it is: its text is not ours to replace.
    assert.deepStrictEqual(write("Service.qml", create, true), { mode: "644", text: "{}", status: 0 })
  },
  "an empty or missing config is the defaults"() {
    assert.deepStrictEqual(Config.parse("").config, Config.DEFAULTS)
    assert.strictEqual(Config.parse("").error, "")
  },
  "a config overrides only what it names"() {
    const { config } = Config.parse('{ "agent": " codex ", "hotkey": "" }')
    assert.strictEqual(config.agent, "codex")
    assert.strictEqual(config.hotkey, "")
    assert.strictEqual(config.folder, "~/Work")
  },
  "a broken config is the defaults, with an error"() {
    for (const text of ["{ oops", "[]", "3", "null"]) {
      const parsed = Config.parse(text)
      assert.deepStrictEqual(parsed.config, Config.DEFAULTS, text)
      assert.ok(parsed.error, text)
    }
  },
  "values of the wrong type or empty fall back"() {
    const { config } = Config.parse('{ "agent": "", "folder": 5, "slide": "left" }')
    assert.strictEqual(config.agent, Config.OMARCHY)
    assert.strictEqual(config.folder, "~/Work")
    assert.strictEqual(config.slide, "top")
  },
  "an update keeps the rest, and keys it does not know"() {
    const text = Config.update('{ "agent": "codex", "mine": 1 }', { folder: "~/Work" })
    assert.deepStrictEqual(JSON.parse(text), Object.assign({ mine: 1 }, Config.DEFAULTS, { agent: "codex", folder: "~/Work" }))
    assert.deepStrictEqual(JSON.parse(Config.update("{ oops", {})), Config.DEFAULTS)
  },
  "an agent is named by its program"() {
    assert.strictEqual(Config.agentName("claude --continue"), "Claude Code")
    assert.strictEqual(Config.agentName("my-agent -x"), "my-agent -x")
  },
  "the default is the agent Omarchy uses, offered first where Omarchy is"() {
    assert.strictEqual(Config.DEFAULTS.agent, Config.OMARCHY)
    assert.strictEqual(Config.agentName(Config.OMARCHY), "Omarchy default agent")
    assert.strictEqual(Config.agentName("omarchy update"), "omarchy update")
    const choices = Config.agentChoices(["claude", "omarchy"], "", Config.OMARCHY)
    assert.deepStrictEqual(choices[0], { command: Config.OMARCHY, name: "Omarchy default agent", off: false, on: true })
    assert.strictEqual(Config.agentChoices(["claude"], "", "claude").filter(c => c.command === Config.OMARCHY)[0].off, true)
  },
  "installed agents come first, missing ones are off"() {
    const choices = Config.agentChoices(["codex", "claude"], "", "codex")
    assert.deepStrictEqual(choices.slice(0, 2).map(c => c.command), ["claude", "codex"])
    assert.strictEqual(choices[1].on, true)
    assert.ok(choices.slice(2).every(c => c.off))
    assert.ok(Config.agentChoices(null, "", "claude").every(c => !c.off))
  },
  "a typed command is offered as is"() {
    assert.deepStrictEqual(Config.agentChoices(["claude"], "claude --continue", "claude")[0],
      { command: "claude --continue", name: "claude --continue", off: false, on: false, custom: true })
    assert.deepStrictEqual(Config.agentChoices(["claude"], "claude", "claude").map(c => c.command), ["claude"])
    assert.strictEqual(Config.agentChoices(["claude"], "", "claude --continue")[0].on, true)
  },
  "a path under home is shortened"() {
    assert.strictEqual(Config.shortPath("/home/me/Projects", "/home/me"), "~/Projects")
    assert.strictEqual(Config.shortPath("/home/me", "/home/me"), "~")
    assert.strictEqual(Config.shortPath("/home/meow", "/home/me"), "/home/meow")
  },

  "a key is read whatever its case and spacing"() {
    assert.deepStrictEqual(Hotkey.parse("super+alt + a"), { mask: 72, key: "A" })
    assert.strictEqual(Hotkey.tidy("ctrl + super + slash"), "SUPER + CTRL + SLASH")
    for (const text of ["", "SUPER + ", "hello world", "super + ctrl", "foo + a", "super + a!"])
      assert.strictEqual(Hotkey.tidy(text), "", JSON.stringify(text))
  },
  "free keys are bound"() {
    const plan = Hotkey.plan(binds(), wanted("SUPER + A", "SUPER + ALT + A"))
    assert.deepStrictEqual(plan.lua, [
      'hl.bind("SUPER + A", toggle(), { description = "Toggle AI scratchpad" })',
      'hl.bind("SUPER + ALT + A", move(), { description = "Move window to AI scratchpad" })',
    ])
    assert.deepStrictEqual(plan.bound, ["SUPER + A", "SUPER + ALT + A"])
    assert.deepStrictEqual(plan.conflicts, [])
  },
  "a taken key is left alone and reported"() {
    const plan = Hotkey.plan(binds(), wanted("SUPER + K", "SUPER + ALT + A"))
    assert.deepStrictEqual(plan.conflicts, [{ setting: "hotkey", hotkey: "SUPER + K", holder: "Keybindings" }])
    assert.deepStrictEqual(plan.bound, ["SUPER + ALT + A"])
    assert.strictEqual(plan.lua.length, 1)
  },
  "what is already bound is not bound again"() {
    const plan = Hotkey.plan(binds([bind(64, "A", Hotkey.TOGGLE), bind(72, "A", Hotkey.MOVE)]), wanted("SUPER + A", "SUPER + ALT + A"))
    assert.deepStrictEqual(plan, { lua: [], bound: ["SUPER + A", "SUPER + ALT + A"], conflicts: [] })
  },
  "a changed key leaves the old one"() {
    const plan = Hotkey.plan(binds([bind(64, "A", Hotkey.TOGGLE)]), wanted("SUPER + I", ""))
    assert.deepStrictEqual(plan.lua, ['hl.unbind("SUPER + A")', 'hl.bind("SUPER + I", toggle(), { description = "Toggle AI scratchpad" })'])
  },
  "one of ours may take the key another of ours leaves"() {
    const plan = Hotkey.plan(binds([bind(64, "A", Hotkey.TOGGLE), bind(72, "A", Hotkey.MOVE)]), wanted("SUPER + ALT + A", "SUPER + I"))
    assert.deepStrictEqual(plan.conflicts, [])
    assert.deepStrictEqual(plan.lua.slice(0, 2), ['hl.unbind("SUPER + A")', 'hl.unbind("SUPER + ALT + A")'])
    assert.strictEqual(plan.lua.length, 4)
  },
  "the same key for both goes to the first"() {
    const plan = Hotkey.plan(binds(), wanted("SUPER + A", "SUPER + A"))
    assert.deepStrictEqual(plan.bound, ["SUPER + A"])
    assert.deepStrictEqual(plan.conflicts, [{ setting: "moveHotkey", hotkey: "SUPER + A", holder: Hotkey.TOGGLE }])
  },
  "no key binds nothing"() {
    assert.deepStrictEqual(Hotkey.plan(binds([bind(64, "A", Hotkey.TOGGLE)]), wanted("", "")),
      { lua: ['hl.unbind("SUPER + A")'], bound: [], conflicts: [] })
  },
  "the other action's key counts as taken when choosing"() {
    const all = binds([bind(64, "A", Hotkey.TOGGLE), bind(72, "A", Hotkey.MOVE)])
    assert.strictEqual(Hotkey.holder(all, "SUPER + A", Hotkey.TOGGLE), "")
    assert.strictEqual(Hotkey.holder(all, "SUPER + A", Hotkey.MOVE), Hotkey.TOGGLE)
  },
  "only agent terminals in the scratchpad count as running"() {
    assert.strictEqual(launcher("--running").out, "1")
  },
  "a restart closes the agent terminals and starts the agent in the scratchpad"() {
    const { status, lines } = launcher("--restart")
    assert.strictEqual(status, 0)
    assert.strictEqual(lines.length, 2)
    assert.strictEqual(lines[0], 'dispatch hl.dsp.window.close({ window = "address:0xa1" })')
    assert.ok(/^dispatch hl\.dsp\.exec_cmd\(".*\/bin\/ai-scratchpad", \{ workspace = "special:ai silent" \}\)$/.test(lines[1]), lines[1])
  },
  "a terminal that stays open is not started over"() {
    const { status, lines } = launcher("--restart", true)
    assert.strictEqual(status, 1)
    assert.strictEqual(lines.length, 2)
    assert.ok(lines[1].indexOf("notify ") === 0, lines[1])
  },
  "the terminal is told nothing of the settings, which other users could read"() {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), "ai-scratchpad-home-"))
    const log = path.join(home, "log")
    fs.mkdirSync(path.join(home, ".config/omarchy/extensions"), { recursive: true })
    fs.writeFileSync(path.join(home, ".config/omarchy/extensions/ai-scratchpad.json"), '{ "agent": "my-agent --key secret", "folder": "~/Private" }')
    fs.writeFileSync(path.join(home, "uwsm-app"), `#!/bin/bash\nprintf '%s\\n' "$*" > "${log}"\n`, { mode: 0o755 })
    const run = spawnSync(path.join(__dirname, "..", "bin", "ai-scratchpad"), [],
      { env: Object.assign({}, process.env, { HOME: home, PATH: home + ":" + process.env.PATH }), encoding: "utf8" })
    const started = fs.readFileSync(log, "utf8").trim()
    fs.rmSync(home, { recursive: true })
    assert.strictEqual(run.status, 0)
    assert.match(started, /^-- xdg-terminal-exec --app-id=org\.omarchy\.ai -e \S+bin\/ai-scratchpad --shell$/)
  },
  "in the terminal the agent runs in its folder, and its command stays out of the arguments"() {
    // A bash of our own in the PATH: it writes down where it is and what it is to run.
    const shell = config => {
      const home = fs.mkdtempSync(path.join(os.tmpdir(), "ai-scratchpad-home-"))
      const log = path.join(home, "log")
      fs.mkdirSync(path.join(home, ".config/omarchy/extensions"), { recursive: true })
      fs.mkdirSync(path.join(home, "Work"))
      if (config) fs.writeFileSync(path.join(home, ".config/omarchy/extensions/ai-scratchpad.json"), config)
      fs.writeFileSync(path.join(home, "bash"), `#!/bin/sh\nprintf '%s\\n%s\\n%s\\n' "$PWD" "$AI_SCRATCHPAD_RUN" "$*" > "${log}"\n`, { mode: 0o755 })
      const run = spawnSync(path.join(__dirname, "..", "bin", "ai-scratchpad"), ["--shell"],
        { env: Object.assign({}, process.env, { HOME: home, PATH: home + ":" + process.env.PATH }), encoding: "utf8" })
      const [where, what, args] = fs.readFileSync(log, "utf8").trim().split("\n")
      fs.rmSync(home, { recursive: true })
      assert.strictEqual(run.status, 0)
      // The command is in the environment; the arguments are the same whatever it is.
      assert.strictEqual(args, '-ic run=$AI_SCRATCHPAD_RUN; unset AI_SCRATCHPAD_RUN; eval "$run"; unset run; exec bash')
      return { where: where.replace(home, "~"), what }
    }
    assert.deepStrictEqual(shell('{ "agent": "KEY=secret my-agent", "folder": "~/Work" }'), { where: "~/Work", what: "KEY=secret my-agent" })
    assert.deepStrictEqual(shell('{ "agent": "my-agent", "folder": "~/Gone" }'), { where: "~", what: "my-agent" })
    const omarchy = shell("")
    assert.strictEqual(omarchy.where, "~/Work")
    assert.match(omarchy.what, /bin\/ai-scratchpad --choose-default; case \$\? in 0\) omarchy agent --inline --pick ;; 1\) exit ;; esac$/)
  },
  "with no Omarchy default the agent is chosen in the terminal, and Esc chooses none"() {
    // An Omarchy of our own: `chosen` holds its default, `log` what it was asked to install.
    const choose = (already, picked) => {
      const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ai-scratchpad-"))
      const chosen = path.join(dir, "chosen")
      const log = path.join(dir, "log")
      if (already) fs.writeFileSync(chosen, already + "\n")
      fs.writeFileSync(path.join(dir, "omarchy-default-agent"), `#!/bin/bash
if (($# == 0)); then cat "${chosen}" 2>/dev/null; exit 0; fi
if [[ $1 == --install ]]; then echo "$2" > "${chosen}"; echo "install $2" >> "${log}"; exit 0; fi
echo "Usage: omarchy-default-agent <pi|claude|codex>"; exit 1
`, { mode: 0o755 })
      fs.writeFileSync(path.join(dir, "gum"), `#!/bin/bash\necho "offered ${"$"}{*: -3}" >> "${log}"\n${picked ? `echo ${picked}` : "exit 130"}\n`, { mode: 0o755 })
      const run = spawnSync(path.join(__dirname, "..", "bin", "ai-scratchpad"), ["--choose-default"],
        { env: Object.assign({}, process.env, { PATH: dir + ":" + process.env.PATH }), encoding: "utf8" })
      const lines = fs.existsSync(log) ? fs.readFileSync(log, "utf8").trim().split("\n") : []
      fs.rmSync(dir, { recursive: true })
      return { status: run.status, lines }
    }
    assert.deepStrictEqual(choose("gemini", "codex"), { status: 0, lines: [] })
    assert.deepStrictEqual(choose("", "codex"), { status: 2, lines: ["offered pi claude codex", "install codex"] })
    assert.deepStrictEqual(choose("", ""), { status: 1, lines: ["offered pi claude codex"] })
  },
  "one taken key is told with its own picker, several in one notification"() {
    const taken = [{ setting: "hotkey", hotkey: "SUPER + K", holder: "Keybindings" }, { setting: "moveHotkey", hotkey: "SUPER + S", holder: "Toggle scratchpad" }]
    const one = Hotkey.notice(taken.slice(0, 1), {})
    assert.strictEqual(one.title, "AI Scratchpad: SUPER + K is taken")
    assert.deepStrictEqual(JSON.parse(one.payload), { setup: "hotkey" })
    const both = Hotkey.notice(taken, {})
    assert.strictEqual(both.title, "AI Scratchpad: 2 shortcuts are taken")
    // What holds a key is not said: other users can read a notification's arguments.
    assert.strictEqual(both.body, "SUPER + K is already in use.\nSUPER + S is already in use.\nClick to choose others.")
    assert.strictEqual(both.payload, "{}")
    assert.deepStrictEqual(both.hotkeys, ["SUPER + K", "SUPER + S"])
  },
  "a taken key is told once"() {
    const taken = [{ setting: "hotkey", hotkey: "SUPER + K", holder: "Keybindings" }, { setting: "moveHotkey", hotkey: "SUPER + S", holder: "Toggle scratchpad" }]
    assert.deepStrictEqual(JSON.parse(Hotkey.notice(taken, { "SUPER + K": true }).payload), { setup: "moveHotkey" })
    assert.strictEqual(Hotkey.notice(taken, { "SUPER + K": true, "SUPER + S": true }), null)
    assert.strictEqual(Hotkey.notice([], {}), null)
  },
  "typed paths list the folders they may mean"() {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), "ai-scratchpad-home-"))
    for (const dir of ["Work/rails", "Work/Rust", "Work/api-rails", "Work/.hidden", "Pictures"]) fs.mkdirSync(path.join(home, dir), { recursive: true })
    fs.writeFileSync(path.join(home, "Work/notes.txt"), "")
    const dirs = text => spawnSync(path.join(__dirname, "..", "bin", "ai-scratchpad"), ["--dirs"],
      { env: Object.assign({}, process.env, { HOME: home, AI_SCRATCHPAD_DIRS: text }), encoding: "utf8" }).stdout.trim().split("\n").filter(Boolean)
    const results = { all: dirs("~/Work/"), typed: dirs("~/Work/r"), hidden: dirs("~/Work/."), top: dirs(""), gone: dirs("~/Gone/x") }
    fs.rmSync(home, { recursive: true })
    assert.deepStrictEqual(results.all, ["~/Work", "~/Work/api-rails", "~/Work/rails", "~/Work/Rust"])
    assert.deepStrictEqual(results.typed, ["~/Work/rails", "~/Work/Rust", "~/Work/api-rails"])
    assert.deepStrictEqual(results.hidden, ["~/Work/.hidden"])
    assert.deepStrictEqual(results.top, ["~", "~/Pictures", "~/Work"])
    assert.deepStrictEqual(results.gone, [])
    // The typed path is taken apart by the shell itself: a program given it
    // as an argument would show it to other users.
    const code = fs.readFileSync(path.join(__dirname, "..", "bin", "ai-scratchpad"), "utf8").split("\n").filter(line => !/^\s*#/.test(line)).join("\n")
    assert.ok(!/\b(dirname|basename)\b/.test(code))
  },
  "a config that does not read starts no agent, and says so"() {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), "ai-scratchpad-home-"))
    const log = path.join(home, "log")
    fs.mkdirSync(path.join(home, ".config/omarchy/extensions"), { recursive: true })
    fs.writeFileSync(path.join(home, ".config/omarchy/extensions/ai-scratchpad.json"), '{ "agent": "careful-agent", }')
    fs.writeFileSync(path.join(home, "bash"), `#!/bin/sh\nprintf '%s|%s|%s\\n' "$PWD" "$AI_SCRATCHPAD_RUN" "$*" > "${log}"\n`, { mode: 0o755 })
    const run = spawnSync(path.join(__dirname, "..", "bin", "ai-scratchpad"), ["--shell"],
      { env: Object.assign({}, process.env, { HOME: home, PATH: home + ":" + process.env.PATH }), encoding: "utf8" })
    const shell = fs.readFileSync(log, "utf8").trim()
    fs.rmSync(home, { recursive: true })
    assert.match(run.stdout, /ai-scratchpad\.json is not valid JSON, so no agent is started/)
    // A plain shell in the home folder: nothing to run, no arguments.
    assert.strictEqual(shell, home + "||")
  },
  "a binding named like something every object has is still somebody else's"() {
    const plan = Hotkey.plan(binds([bind(64, "A", "constructor")]), wanted("SUPER + A", "SUPER + ALT + A"))
    assert.deepStrictEqual(plan.conflicts, [{ setting: "hotkey", hotkey: "SUPER + A", holder: "constructor" }])
    assert.deepStrictEqual(plan.bound, ["SUPER + ALT + A"])
  },
  "only installed agents are reported"() {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), "ai-scratchpad-home-"))
    const run = spawnSync(path.join(__dirname, "..", "bin", "ai-scratchpad"), ["--agents", "sh", "no-such-agent-here", "ls"],
      { env: Object.assign({}, process.env, { HOME: home }), encoding: "utf8" })
    fs.rmSync(home, { recursive: true })
    assert.deepStrictEqual(run.stdout.trim().split("\n"), ["sh", "ls"])
  },
  "free choices come first, a typed key is offered"() {
    const choices = Hotkey.choices(binds([bind(64, "A", "Something")]), "", Hotkey.IDEAS.hotkey, Hotkey.TOGGLE)
    assert.strictEqual(choices.length, Hotkey.IDEAS.hotkey.length)
    assert.deepStrictEqual(choices[choices.length - 1], { hotkey: "SUPER + A", holder: "Something" })
    assert.deepStrictEqual(Hotkey.choices(binds(), "super+f9", Hotkey.IDEAS.hotkey, Hotkey.TOGGLE), [{ hotkey: "SUPER + F9", holder: "" }])
    assert.ok(Hotkey.choices(binds(), "a", Hotkey.IDEAS.hotkey, Hotkey.TOGGLE).every(choice => choice.hotkey !== "A"))
  },
}

let failed = 0
for (const [name, test] of Object.entries(tests)) {
  try { test(); console.log("ok   " + name) }
  catch (error) { failed++; console.log("FAIL " + name + "\n     " + String(error.message).split("\n").join("\n     ")) }
}
process.exit(failed ? 1 : 0)
