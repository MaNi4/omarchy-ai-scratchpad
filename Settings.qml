import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "Config.js" as Config
import "Hotkey.js" as Hotkey

// The settings of the AI scratchpad as an Omarchy menu: its keys, the agent
// and the folder. Everything chosen here is written to the config file, which
// Service.qml and bin/ai-scratchpad read; this file only draws and saves.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  // "settings", or the one being chosen: "hotkey", "moveHotkey", "settingsHotkey", "agent", "folder";
  // "restart" asks whether a new agent or folder should apply to the running agent.
  property string page: "settings"
  property string changed: ""       // the setting the restart question is about
  property string changedNote: ""   // what the change does when the agent keeps running
  property int running: 0           // agent terminals open in the scratchpad
  property bool direct: false       // opened on one setting: choosing closes, there is no way back
  property var rows: []
  property int selectedIndex: 0
  property string configText: ""
  property var config: Config.parse("").config
  property string bindsJson: ""     // `hyprctl binds -j`, to tell free keys from taken ones
  property var installed: null      // the agents found on this machine; null until known
  property string omarchyAgent: ""  // the agent chosen as Omarchy's default, "" when none is
  property var folders: []          // the folders the typed path may mean
  // Nothing is drawn until there is something to list, so the menu appears
  // once, whole. The window is up from the start: keys typed in that moment
  // already land in the field.
  property bool ready: false

  readonly property string pluginId: (manifest && manifest.id) || "mani4.ai-scratchpad"
  readonly property string pluginDir: {
    var s = String(Qt.resolvedUrl("."))
    return s.indexOf("file://") === 0 ? s.substring(7) : s
  }
  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: home + "/.config/omarchy/extensions/ai-scratchpad.json"
  readonly property var selectedRow: rows[selectedIndex] || null
  readonly property var titles: ({ settings: "AI Scratchpad", hotkey: "Open the scratchpad with",
    moveHotkey: "Move a window to it with", settingsHotkey: "Open these settings with", agent: "Agent", folder: "Folder",
    restart: "Restart the agent?" })
  readonly property var placeholders: ({ settings: "Search", hotkey: "Pick one, or type your own",
    moveHotkey: "Pick one, or type your own", settingsHotkey: "Pick one, or type your own", agent: "Pick one, or type a command", folder: "Type a path", restart: "" })

  // Menu surface tokens, so a theme that styles the Omarchy menu styles this.
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color scrim: Color.menu.scrim
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int inputFont: Style.font.heading
  readonly property int inputHeight: Math.max(Style.space(38), inputFont + Style.spacing.controlPaddingY * 2)
  readonly property int rowHeight: Math.max(Style.space(34), Style.font.subtitle + Style.spacing.lg * 2)
  readonly property int footerHeight: Math.max(Style.space(30), Style.font.caption + Style.spacing.md * 2)
  readonly property int maxRows: 10
  readonly property int cardWidth: Math.min(Style.space(680), panel.width - Style.gapsOut * 2)
  // Rows only take the selection on hover when the pointer really moved, so
  // a list that changes under a resting pointer does not move it.
  property point lastPointer: Qt.point(-1, -1)

  readonly property string message: {
    if (rows.length > 0) return ""
    if (titles[page] && page.indexOf("otkey") >= 0) return "Type a key combination, like SUPER + ALT + A."
    if (page === "folder") return "No folder matches “" + input.text.trim() + "”."
    return "Nothing matches “" + input.text.trim() + "”."
  }

  // ---------------------------------------------------------------- lifecycle

  // payloadJson may name one setting to open on: '{"setup": "hotkey"}'.
  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) {}
    root.direct = ["hotkey", "moveHotkey", "settingsHotkey", "agent", "folder"].indexOf(payload.setup) >= 0
    root.ready = false
    readyGuard.restart()
    root.lastPointer = Qt.point(-1, -1)
    configFile.reload()
    bindsReader.running = true
    runningReader.running = true
    defaultReader.running = true
    if (root.installed === null) agentsReader.running = true
    root.show(root.direct ? payload.setup : "settings")
    root.opened = true
    Qt.callLater(function() { input.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  Timer {
    id: readyGuard
    interval: 400
    onTriggered: root.ready = true
  }

  // ---------------------------------------------------------------- settings

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyConfig(text())
    onLoadFailed: root.applyConfig("")
    onFileChanged: reload()
  }

  function applyConfig(text) {
    root.configText = text
    root.config = Config.parse(text).config
    root.recompute()
  }

  // A file with text that does not read as JSON: the defaults are in effect.
  function broken() {
    return root.configText.trim() !== "" && Config.parse(root.configText).error !== ""
  }

  // false when nothing was saved. A file that does not read is not ours to
  // replace: saving the defaults over it would lose what is in it.
  function save(changes) {
    if (root.broken()) {
      root.note("The config file is not valid JSON, so nothing was changed. Fix it with \"Edit the config file\".")
      return false
    }
    var text = Config.update(root.configText, changes)
    // Shown at once; the file watcher confirms it a moment later.
    root.applyConfig(text)
    writer.save(text)
    return true
  }

  // The config may hold a command with something private in it, and other
  // users can read a process's arguments: the text goes over stdin. For the
  // same reason the file is for its owner alone, whatever it was before.
  Process {
    id: writer
    property string text: ""
    property bool again: false
    command: ["sh", "-c", 'umask 077; mkdir -p "$(dirname "$1")" && { [ ! -e "$1" ] || chmod go-rwx "$1"; } && cat > "$1"', "sh", root.configPath]
    stdinEnabled: true
    function save(next) {
      text = next
      if (running) { again = true; return }
      running = true
    }
    onStarted: {
      write(text)
      stdinEnabled = false
    }
    onExited: {
      stdinEnabled = true
      if (again) { again = false; running = true }
    }
  }

  // The agent's command and the folder never go in here: other users can
  // read the arguments. A key combination may.
  function note(body) {
    Quickshell.execDetached(["notify-send", "-a", "AI Scratchpad", "AI Scratchpad", body])
  }

  // A choice is made: back to the list it was opened from, or done.
  function choose(changes, body) {
    if (!root.save(changes)) return root.dismiss()
    root.done(body)
  }

  function done(body) {
    if (root.direct) { root.note(body); root.dismiss() }
    else root.leave()
  }

  // A new agent or folder only reaches an agent that starts after it. One
  // that is running is not ours to redirect: ask whether to start it anew.
  function chooseForAgent(setting, changes, body) {
    var same = root.config[setting] === changes[setting]
    if (!root.save(changes)) return root.dismiss()
    if (same || root.running === 0) return root.done(body)
    root.changed = setting
    root.changedNote = body
    root.show("restart")
  }

  function restartRows() {
    return [
      { type: "keep", label: "Keep it running", key: "", value: "", where: "applies the next time the scratchpad is opened empty" },
      { type: "restart", label: "Restart the agent now", key: "", value: "", where: "ends what is running in it" },
    ]
  }

  Process {
    id: bindsReader
    command: ["hyprctl", "binds", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.bindsJson = String(text || "")
        root.recompute()
        root.ready = true
      }
    }
  }

  Process {
    id: runningReader
    command: [root.pluginDir + "bin/ai-scratchpad", "--running"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.running = parseInt(String(text || "").trim()) || 0
    }
  }

  Process {
    id: defaultReader
    command: ["omarchy-default-agent"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.omarchyAgent = String(text || "").trim()
        root.recompute()
      }
    }
  }

  Process {
    id: agentsReader
    command: [root.pluginDir + "bin/ai-scratchpad", "--agents"].concat(Config.AGENTS.map(function(agent) { return Config.program(agent.command) }))
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.installed = String(text || "").split("\n").filter(function(line) { return line !== "" })
        root.recompute()
      }
    }
  }

  // The folders are listed anew for every change to the path; one that is
  // typed while a listing runs waits for it.
  Process {
    id: foldersReader
    property string query: ""
    property bool again: false
    // The typed path goes in the environment, which only we can read.
    command: [root.pluginDir + "bin/ai-scratchpad", "--dirs"]
    environment: ({ AI_SCRATCHPAD_DIRS: query })
    function list(text) {
      if (running) { again = true; return }
      query = text
      running = true
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.folders = String(text || "").split("\n").filter(function(line) { return line !== "" })
        if (root.page === "folder") root.recompute()
      }
    }
    onRunningChanged: {
      if (running || !again) return
      again = false
      if (root.page === "folder") list(input.text)
    }
  }

  // ---------------------------------------------------------------- rows

  // A key somebody else holds is not bound: the row says who has it.
  function hotkeyRow(page, label, where, description) {
    var key = Hotkey.tidy(root.config[page])
    var holder = Hotkey.holder(root.bindsJson, key, description)
    return { type: "page", page: page, label: label, where: holder ? "taken by “" + holder + "”, choose another" : where,
             key: key, value: key ? "" : "none" }
  }

  function settingsRows() {
    var all = [
      { type: "page", page: "agent", label: "Agent", where: "what runs in it", key: "", value: Config.agentName(root.config.agent) },
      { type: "page", page: "folder", label: "Folder", where: "where the agent starts", key: "", value: root.config.folder },
      { type: "slide", label: "Slides in from", where: "", key: "", value: root.config.slide === "top" ? "the top" : "the bottom" },
      root.hotkeyRow("hotkey", "Shortcut", "shows and hides the scratchpad", Hotkey.TOGGLE),
      root.hotkeyRow("moveHotkey", "Move window shortcut", "sends the focused window to it", Hotkey.MOVE),
      root.hotkeyRow("settingsHotkey", "Settings shortcut", "opens this list", Hotkey.SETTINGS),
      { type: "file", label: "Edit the config file", where: Config.shortPath(root.configPath, root.home), key: "", value: "" },
    ]
    var query = input.text.trim().toLowerCase()
    return all.filter(function(row) { return !query || (row.label + " " + row.where).toLowerCase().indexOf(query) >= 0 })
  }

  // The key picker's rows; Hotkey.js decides which keys and in what order.
  function hotkeyRows() {
    var description = root.page === "hotkey" ? Hotkey.TOGGLE : root.page === "moveHotkey" ? Hotkey.MOVE : Hotkey.SETTINGS
    var current = Hotkey.tidy(root.config[root.page])
    var rows = Hotkey.choices(root.bindsJson, input.text, Hotkey.IDEAS[root.page], description).map(function(choice) {
      return { type: "hotkey", hotkey: choice.hotkey, label: choice.hotkey, key: "", value: "", off: choice.holder !== "",
               on: choice.hotkey === current, where: choice.holder ? "runs “" + choice.holder + "”" : "free" }
    })
    if (!input.text.trim())
      rows.push({ type: "hotkey", hotkey: "", label: "No shortcut", key: "", value: "", off: false, on: current === "", where: "bind it yourself, or not at all" })
    return rows
  }

  function agentRows() {
    return Config.agentChoices(root.installed, input.text, root.config.agent).map(function(choice) {
      return { type: "agent", command: choice.command, label: choice.name, key: "", value: "", off: choice.off, on: choice.on,
               where: choice.custom ? "your own command" : choice.off ? "not installed"
                 : choice.command !== Config.OMARCHY ? choice.command
                 : root.omarchyAgent ? "now " + Config.agentName(root.omarchyAgent) : "none chosen yet, asks the first time" }
    })
  }

  function folderRows() {
    return root.folders.map(function(folder) {
      return { type: "folder", label: folder, key: "", value: "", off: false, on: folder === root.config.folder, where: "" }
    })
  }

  function recompute() {
    var next = root.page === "settings" ? root.settingsRows()
      : root.page === "agent" ? root.agentRows()
      : root.page === "folder" ? root.folderRows()
      : root.page === "restart" ? root.restartRows()
      : root.hotkeyRows()
    root.rows = next
    if (root.selectedIndex >= next.length) root.selectedIndex = Math.max(0, next.length - 1)
  }

  function move(step) {
    if (root.rows.length === 0) return
    root.selectedIndex = Math.max(0, Math.min(root.rows.length - 1, root.selectedIndex + step))
    list.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function show(page) {
    root.page = page
    root.selectedIndex = 0
    root.folders = []
    // The folder is chosen by editing its path: start from the one in use.
    var text = page === "folder" ? root.config.folder.replace(/\/+$/, "") + "/" : ""
    if (input.text === text) root.typed()
    else input.text = text
    list.positionViewAtBeginning()
  }

  function typed() {
    root.selectedIndex = 0
    if (root.page === "folder") foldersReader.list(input.text)
    root.recompute()
    list.positionViewAtBeginning()
  }

  // Back to the settings, on the row we came from.
  function leave() {
    if (root.page === "settings" || root.direct) return false
    var left = root.page === "restart" ? root.changed : root.page
    root.show("settings")
    for (var i = 0; i < root.rows.length; i++) if (root.rows[i].page === left) root.selectedIndex = i
    return true
  }

  function activate(index) {
    var row = root.rows[index]
    if (!row || row.off) return
    if (row.type === "page") {
      root.show(row.page)
    } else if (row.type === "slide") {
      if (!root.save({ slide: root.config.slide === "top" ? "bottom" : "top" })) root.dismiss()
    } else if (row.type === "file") {
      // An empty file would open: write what is in effect first. One that
      // does not read is opened as it is, to be fixed.
      if (!root.broken()) root.save({})
      Quickshell.execDetached(["omarchy-launch-editor", root.configPath])
      root.dismiss()
    } else if (row.type === "hotkey") {
      var change = {}
      change[root.page] = row.hotkey
      var does = root.page === "hotkey" ? "shows and hides the AI scratchpad."
        : root.page === "moveHotkey" ? "moves the focused window to the AI scratchpad." : "opens the AI scratchpad settings."
      root.choose(change, row.hotkey ? row.hotkey + " " + does : "No key " + does)
    } else if (row.type === "agent") {
      root.chooseForAgent("agent", { agent: row.command }, "The new agent starts the next time the scratchpad is opened empty.")
    } else if (row.type === "folder") {
      root.chooseForAgent("folder", { folder: row.label }, "The agent starts in the new folder the next time the scratchpad is opened empty.")
    } else if (row.type === "keep") {
      root.done(root.changedNote)
    } else if (row.type === "restart") {
      Quickshell.execDetached([root.pluginDir + "bin/ai-scratchpad", "--restart"])
      root.done("The agent starts anew.")
    }
  }

  // ---------------------------------------------------------------- pieces

  component Keycap: Rectangle {
    id: cap
    property string label: ""
    property color tint: root.foreground
    implicitWidth: Math.max(implicitHeight, capText.implicitWidth + Style.space(10))
    implicitHeight: capText.implicitHeight + Style.space(4)
    radius: root.cornerRadius > 0 ? Style.space(4) : 0
    color: Util.alpha(cap.tint, 0.08)
    border.width: 1
    border.color: Util.alpha(cap.tint, 0.18)

    Text {
      textFormat: Text.PlainText
      id: capText
      anchors.centerIn: parent
      text: cap.label
      color: cap.tint
      opacity: 0.8
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component Hint: Row {
    property string keyLabel: ""
    property string text: ""
    spacing: Style.space(5)
    Keycap { label: parent.keyLabel; anchors.verticalCenter: parent.verticalCenter }
    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: parent.text
      color: root.foreground
      opacity: 0.5
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // ---------------------------------------------------------------- window

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-ai-scratchpad"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
      opacity: root.ready ? 1 : 0
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: contentTopInset + contentBottomInset + layout.implicitHeight
      radius: root.cornerRadius
      anchors.horizontalCenter: parent.horizontalCenter
      y: Math.round(panel.height * 0.2)
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding
      opacity: root.ready ? 1 : 0

      MouseArea { anchors.fill: parent; onClicked: input.forceActiveFocus() }

      Column {
        id: layout
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: card.contentTopInset
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        spacing: Style.spacing.md

        // ---------- where we are, and the search field ----------
        Item {
          width: parent.width
          height: root.inputHeight

          Row {
            id: trail
            anchors.left: parent.left
            anchors.leftMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            // The settings, then the one being chosen; the last one is where we are.
            Repeater {
              model: root.page === "settings" || root.direct ? [root.titles[root.page]] : [root.titles.settings, root.titles[root.page]]
              Row {
                id: crumb
                required property string modelData
                required property int index
                readonly property bool here: root.page === "settings" || root.direct || index === 1
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: crumb.modelData
                  color: root.foreground
                  opacity: crumb.here ? 0.9 : 0.5
                  font.family: root.fontFamily
                  font.pixelSize: root.inputFont
                  elide: Text.ElideRight
                  width: Math.min(implicitWidth, root.cardWidth * (crumb.here ? 0.34 : 0.16))
                }
                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: "›"
                  color: root.foreground
                  opacity: 0.4
                  font.family: root.fontFamily
                  font.pixelSize: root.inputFont
                }
              }
            }
          }

          TextInput {
            id: input
            anchors.left: trail.right
            anchors.leftMargin: Style.space(6)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            color: root.foreground
            selectionColor: root.selectedBackground
            selectedTextColor: root.selectedText
            font.family: root.fontFamily
            font.pixelSize: root.inputFont
            clip: true
            focus: true
            onTextChanged: {
              root.typed()
            }

            Text {
              textFormat: Text.PlainText
              anchors.fill: parent
              verticalAlignment: Text.AlignVCenter
              visible: !input.text
              text: root.placeholders[root.page]
              color: root.foreground
              opacity: 0.4
              font: input.font
            }

            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) {
              var ctrl = event.modifiers & Qt.ControlModifier
              var atEnd = input.cursorPosition === input.text.length
              var section = root.selectedRow && root.selectedRow.type === "page"
              var folder = root.page === "folder" && root.selectedRow
              if (event.key === Qt.Key_Escape) {
                if (input.text && root.page !== "folder") input.text = ""
                else if (!root.leave()) root.dismiss()
              } else if (event.key === Qt.Key_Down || (ctrl && (event.key === Qt.Key_N || event.key === Qt.Key_J))) {
                root.move(1)
              } else if (event.key === Qt.Key_Up || (ctrl && (event.key === Qt.Key_P || event.key === Qt.Key_K))) {
                root.move(-1)
              } else if (event.key === Qt.Key_PageDown) {
                root.move(root.maxRows - 1)
              } else if (event.key === Qt.Key_PageUp) {
                root.move(1 - root.maxRows)
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.activate(root.selectedIndex)
              } else if (event.key === Qt.Key_Tab || (event.key === Qt.Key_Right && atEnd)) {
                // Into a setting, or into a folder; elsewhere the key does nothing, as in a menu.
                if (section) root.activate(root.selectedIndex)
                else if (folder) input.text = root.selectedRow.label.replace(/\/+$/, "") + "/"
                else if (event.key === Qt.Key_Right) return
              } else if (event.key === Qt.Key_Backtab || ((event.key === Qt.Key_Left || event.key === Qt.Key_Backspace) && !input.text)) {
                if (!root.leave() && event.key !== Qt.Key_Backtab) return
              } else {
                return
              }
              event.accepted = true
            }
          }

        }

        Rectangle {
          width: parent.width
          height: 1
          color: Util.alpha(root.foreground, 0.1)
        }

        // ---------- what there is ----------
        ListView {
          id: list
          width: parent.width
          height: Math.min(root.rows.length, root.maxRows) * root.rowHeight
          visible: root.rows.length > 0
          model: root.rows
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          currentIndex: root.selectedIndex

          delegate: Item {
            id: rowItem
            required property int index
            required property var modelData
            readonly property bool selected: index === root.selectedIndex
            readonly property bool section: modelData.type === "page"
            readonly property bool off: !!modelData.off
            readonly property color ink: selected && !off ? root.selectedText : root.foreground

            width: list.width
            height: root.rowHeight

            Rectangle {
              anchors.fill: parent
              radius: root.cornerRadius > 0 ? Style.space(6) : 0
              color: rowItem.selected ? root.selectedBackground : "transparent"
            }

            // A folder for a folder, a tick for what is in use.
            Text {
              textFormat: Text.PlainText
              id: tick
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(18)
              horizontalAlignment: Text.AlignHCenter
              text: rowItem.modelData.on ? "✓" : rowItem.modelData.type === "folder" ? "󰉋" : ""
              color: rowItem.ink
              opacity: rowItem.off ? 0.4 : rowItem.modelData.on ? 0.9 : 0.65
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
            }

            Text {
              textFormat: Text.PlainText
              id: label
              anchors.left: tick.right
              anchors.leftMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, parent.width - tick.width - trailing.width - Style.spacing.md * 4)
              text: rowItem.modelData.label
              color: rowItem.ink
              opacity: rowItem.off ? 0.4 : 1
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              elide: Text.ElideRight
            }

            // What the row is about: "free", "not installed".
            Text {
              textFormat: Text.PlainText
              anchors.left: label.right
              anchors.leftMargin: Style.spacing.lg
              anchors.right: trailing.left
              anchors.rightMargin: Style.spacing.lg
              anchors.verticalCenter: parent.verticalCenter
              visible: text !== ""
              text: rowItem.modelData.where || ""
              color: rowItem.ink
              opacity: rowItem.off ? 0.25 : 0.45
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            Row {
              id: trailing
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.lg
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)
              opacity: rowItem.off ? 0.4 : 1

              Repeater {
                model: rowItem.modelData.key ? rowItem.modelData.key.split(" + ") : []
                Keycap {
                  required property string modelData
                  anchors.verticalCenter: parent.verticalCenter
                  label: modelData
                  tint: rowItem.ink
                }
              }

              // What the setting is now.
              Text {
                textFormat: Text.PlainText
                visible: text !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: rowItem.modelData.value || ""
                color: rowItem.ink
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideMiddle
                width: Math.min(implicitWidth, root.cardWidth * 0.4)
              }

              Text {
                textFormat: Text.PlainText
                visible: rowItem.section
                anchors.verticalCenter: parent.verticalCenter
                text: "›"
                color: rowItem.ink
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: rowItem.off ? Qt.ArrowCursor : Qt.PointingHandCursor
              onPositionChanged: function(mouse) {
                var p = mapToItem(null, mouse.x, mouse.y)
                if (p.x === root.lastPointer.x && p.y === root.lastPointer.y) return
                var first = root.lastPointer.x < 0
                root.lastPointer = Qt.point(p.x, p.y)
                if (!first) root.selectedIndex = rowItem.index
              }
              onClicked: {
                input.forceActiveFocus()
                root.selectedIndex = rowItem.index
                // Last: it may replace the rows, and this one with them.
                root.activate(rowItem.index)
              }
            }
          }
        }

        // ---------- nothing to list ----------
        Text {
          textFormat: Text.PlainText
          width: parent.width
          height: root.rowHeight * 2
          visible: root.rows.length === 0 && root.ready
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          wrapMode: Text.WordWrap
          text: root.message
          color: root.foreground
          opacity: 0.55
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
        }

        // ---------- what the keys do ----------
        Item {
          width: parent.width
          height: root.footerHeight
          visible: root.rows.length > 0

          Rectangle {
            anchors.top: parent.top
            width: parent.width
            height: 1
            color: Util.alpha(root.foreground, 0.1)
          }

          Row {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(4)
            anchors.bottom: parent.bottom
            spacing: Style.spacing.xxl

            Hint {
              keyLabel: "↵"
              text: !root.selectedRow ? "" : root.selectedRow.type === "page" ? "Change"
                : root.selectedRow.type === "slide" ? "Switch"
                : root.selectedRow.type === "file" ? "Open in the editor"
                : root.selectedRow.type === "hotkey" ? (root.selectedRow.off ? "Taken" : root.selectedRow.hotkey ? "Use this key" : "Use no key")
                : root.selectedRow.type === "agent" ? (root.selectedRow.off ? "Not installed" : "Use this agent")
                : root.selectedRow.type === "keep" ? "Keep it running"
                : root.selectedRow.type === "restart" ? "Restart"
                : "Use this folder"
            }
            Hint { keyLabel: "⇥"; text: "Open the folder"; visible: root.page === "folder" }
          }

          Hint {
            anchors.right: parent.right
            anchors.rightMargin: Style.space(4)
            anchors.bottom: parent.bottom
            keyLabel: "esc"
            text: input.text && root.page !== "folder" ? "Clear" : root.page !== "settings" && !root.direct ? "Back" : "Close"
          }
        }
      }
    }
  }
}
