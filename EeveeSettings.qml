import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Eevee's settings window, built from the shell's own UI kit so it looks like
// the rest of Omarchy. Every change is saved at once through Buddy.qml's
// setSetting() into the plugin's entry in shell.json; actions (lock screen,
// memory, evolving) go through bin/eevee-brain.
Scope {
  id: ui

  required property var buddy
  property bool shown: false

  readonly property var s: ui.buddy.settings
  readonly property color fg: Color.foreground
  readonly property color accent: Color.accent
  readonly property string fontFamily: Style.font.family
  readonly property color dim: Qt.rgba(ui.fg.r, ui.fg.g, ui.fg.b, 0.6)
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/eevee"

  function set(key, value) { ui.buddy.setSetting(key, value) }

  // Float it, centred, the first time it maps: a runtime Hyprland rule, so
  // nothing has to be added to the user's config.
  // Sized to fit the monitor it opens on.
  readonly property int windowWidth: 620
  property int windowHeight: 760
  function open() {
    if (ui.shown) return
    var screens = Quickshell.screens, h = 760
    for (var i = 0; i < screens.length; i++)
      if (screens[i].name === ui.buddy.focusedScreen) h = Math.min(760, screens[i].height - 140)
    ui.windowHeight = Math.max(420, h)
    floatRule.command = ["hyprctl", "eval", "hl.window_rule({ match = { class = \"^org.quickshell$\", title = \"^Eevee settings$\" }, float = true, center = true, size = { "
      + ui.windowWidth + ", " + ui.windowHeight + " } })"]
    floatRule.running = true
  }
  Process {
    id: floatRule
    onExited: ui.shown = true
  }
  function brain(args) { Quickshell.execDetached(["bash", ui.buddy.brain].concat(args)) }

  onShownChanged: if (shown) { lockStatus.running = true; hookStatus.running = true; memoryFile.reload() }

  // ---- state the window shows -------------------------------------------
  property string lockState: "" // on | off | missing | "" (checking)
  property string hookState: "" // on | off | "" (checking)
  property int memoryCount: 0

  Process {
    id: lockStatus
    command: ["bash", ui.buddy.brain, "lockscreen", "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: ui.lockState = String(text || "").trim()
    }
  }
  Process {
    id: lockSwitch
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: ui.lockState = String(text || "").trim()
    }
  }
  Process {
    id: hookStatus
    command: ["bash", ui.buddy.brain, "cmdhook", "status"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: ui.hookState = String(text || "").trim() }
  }
  Process {
    id: hookSwitch
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: ui.hookState = String(text || "").trim() }
  }
  FileView {
    id: memoryFile
    path: ui.stateDir + "/memory"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: ui.memoryCount = String(text() || "").split("\n").filter(function(l) { return l.trim() !== "" }).length
    onLoadFailed: ui.memoryCount = 0
  }

  readonly property var formNames: ["eevee", "vaporeon", "jolteon", "flareon", "espeon", "umbreon", "leafeon", "glaceon", "sylveon"]
  readonly property var modelOptions: [
    { value: "claude-haiku-4-5", label: "Haiku 4.5 · fastest" },
    { value: "claude-sonnet-5", label: "Sonnet 5 · balanced" },
    { value: "claude-opus-5-5", label: "Opus 5.5 · smartest" }
  ]
  readonly property var screenOptions: {
    var o = [{ value: "follow", label: "Follow my focus" }]
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) o.push({ value: screens[i].name, label: screens[i].name })
    return o
  }

  // A row with a title and description on the left and any control on the
  // right, framed like the kit's Toggle rows.
  component SettingRow: BorderSurface {
    id: row
    property string label: ""
    property string description: ""
    default property alias control: slot.data
    width: parent ? parent.width : 0
    implicitHeight: Math.max(54, Math.max(texts.implicitHeight, slot.height) + Style.spacing.huge)
    radius: Style.cornerRadius
    color: Style.controlFill(false, rowHover.hovered, ui.fg, ui.accent)
    borderSpec: Border.controlSpec(rowHover.hovered ? "hover-cursor" : "normal", ui.fg, ui.accent)
    HoverHandler { id: rowHover }

    Column {
      id: texts
      anchors.left: parent.left
      anchors.right: slot.left
      anchors.leftMargin: Style.space(14)
      anchors.rightMargin: Style.space(14)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)
      Text {
        width: parent.width
        text: row.label
        color: ui.fg
        font.family: ui.fontFamily
        font.pixelSize: Style.font.subtitle
        elide: Text.ElideRight
      }
      Text {
        width: parent.width
        visible: row.description !== ""
        text: row.description
        color: ui.dim
        font.family: ui.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
    Item {
      id: slot
      anchors.right: parent.right
      anchors.rightMargin: Style.space(14)
      anchors.verticalCenter: parent.verticalCenter
      width: childrenRect.width
      height: childrenRect.height
    }
  }

  component SettingToggle: Toggle {
    property string key: ""
    width: parent ? parent.width : 0
    foreground: ui.fg
    accent: ui.accent
    fontFamily: ui.fontFamily
    checked: ui.s[key] === true
    onClicked: ui.set(key, !checked)
  }

  component Section: PanelSectionHeader {
    foreground: ui.fg
    fontFamily: ui.fontFamily
    topPadding: Style.space(8)
  }

  FloatingWindow {
    id: window
    visible: ui.shown
    title: "Eevee settings"
    color: Color.background
    implicitWidth: ui.windowWidth
    implicitHeight: ui.windowHeight
    minimumSize: Qt.size(420, 400)
    onVisibleChanged: if (!visible) ui.shown = false

    FocusScope {
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: ui.shown = false

      ScrollView {
        id: scroll
        anchors.fill: parent
        anchors.margins: Style.space(18)
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        Column {
          width: scroll.availableWidth
          spacing: Style.space(10)

          // ---- header: Eevee herself, her form and your friendship ------
          Row {
            width: parent.width
            spacing: Style.space(16)

            Item {
              id: portrait
              readonly property string sheet: ui.buddy.forms[ui.buddy.shownForm] ? ui.buddy.shownForm : "eevee"
              readonly property var spec: ui.buddy.specOf(sheet, "Idle")
              readonly property int px: 3
              property int frame: 0
              width: spec.w * px
              height: spec.h * px
              clip: true
              Image {
                source: ui.buddy.forms[portrait.sheet] ? "forms/" + portrait.sheet + (ui.buddy.shiny ? "/shiny/" : "/") + "Idle.png" : ""
                smooth: false
                width: sourceSize.width * portrait.px
                height: sourceSize.height * portrait.px
                x: -portrait.frame * portrait.width
                y: 0 // first row faces the viewer
              }
              Timer {
                running: ui.shown
                repeat: true
                interval: Math.round(portrait.spec.d[portrait.frame % portrait.spec.d.length] * 1000 / 60)
                onTriggered: portrait.frame = (portrait.frame + 1) % portrait.spec.d.length
              }
            }

            Column {
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)
              Text {
                text: (ui.buddy.evolves ? ui.buddy.pretty(ui.buddy.form) : ui.buddy.speciesLabel) + (ui.buddy.shiny ? " ✦" : "")
                color: ui.fg
                font.family: ui.fontFamily
                font.pixelSize: Style.font.iconLarge
              }
              Text {
                text: "Friendship " + ui.buddy.friendship + "/10 · pets and chats make her livelier"
                color: ui.dim
                font.family: ui.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---- Eevee --------------------------------------------------------
          Section { text: "Buddy" }

          SettingRow {
            label: "Pokémon"
            description: "Who lives on your desktop. Only Eevee evolves."
            Dropdown {
              width: Style.spacing.dropdownWidth
              showLabel: false
              fontFamily: ui.fontFamily
              options: ui.buddy.speciesList.map(function(sp) { return { value: sp.id, label: sp.label } })
              value: ui.buddy.species
              onChanged: function(v) { ui.set("species", v) }
            }
          }

          SettingRow {
            label: "Shiny"
            description: "Rare is like the games: a 1 in 4096 chance each day."
            ButtonGroup {
              fontFamily: ui.fontFamily
              foreground: ui.fg
              accent: ui.accent
              options: [{ value: "rare", label: "Rare" }, { value: "always", label: "Always" }, { value: "never", label: "Never" }]
              value: String(ui.s.shiny)
              onChanged: function(v) { ui.set("shiny", v) }
            }
          }

          SettingRow {
            label: "Screen"
            description: "Where she lives. Following your focus moves her to the monitor you're working on."
            Dropdown {
              width: Style.spacing.dropdownWidth
              showLabel: false
              fontFamily: ui.fontFamily
              options: ui.screenOptions
              value: String(ui.s.screen)
              onChanged: function(v) { ui.set("screen", v) }
            }
          }

          SettingRow {
            label: "Size"
            ButtonGroup {
              fontFamily: ui.fontFamily
              foreground: ui.fg
              accent: ui.accent
              options: [{ value: "2", label: "Small" }, { value: "3", label: "Medium" }, { value: "4", label: "Large" }]
              value: String(ui.s.size)
              onChanged: function(v) { ui.set("size", Number(v)) }
            }
          }

          SettingToggle { key: "attacks"; label: "Attacks"; description: "Use her type's move when something fits: Electric types on plugging in the charger, Fire when the CPU runs hot, Water after a break, Grass in the morning, Ice when it's cool, Ghost and Dark when a service fails, Fairy when petted, Psychic after answering. Everyone attacks when a long command finishes. /attack any time." }
          SettingToggle { key: "wander"; label: "Wander around"; description: "Walk along the bottom of the screen. Off, she stays where you put her." }
          SettingToggle { key: "music"; label: "Bop to music"; description: "Nod along while a media player is playing." }
          SettingToggle { key: "musicControls"; label: "Music controls on hover"; description: "Hover over her to see the track with previous, play/pause and next (Spotify or any media player)." }
          SettingToggle { key: "hoverStatus"; label: "Status on hover"; description: "When nothing is playing, hovering shows CPU, memory, heat, battery and your next reminder." }
          SettingToggle { visible: ui.buddy.evolves; key: "evolution"; label: "Evolve on her own"; description: "Now and then turn into an Eeveelution that fits the moment: heat, charging, time of day, breaks, pets." }

          SettingRow {
            visible: ui.buddy.evolves
            label: "Evolve now"
            description: "Try a form. It wears off after 20–40 minutes."
            Dropdown {
              width: Style.spacing.dropdownWidth
              showLabel: false
              fontFamily: ui.fontFamily
              options: ui.formNames.map(function(f) { return { value: f, label: ui.buddy.pretty(f) } })
              value: ui.buddy.form
              onChanged: function(v) { ui.buddy.requestEvolve(v) }
            }
          }

          // ---- Notifications -----------------------------------------------
          Section { text: "Notifications" }

          SettingToggle {
            key: "notifications"
            label: "Deliver notifications"
            description: "Show them in Eevee's bubble instead of Omarchy's popups. Uses Do Not Disturb to silence the popups; everything still goes to the notification history."
          }

          SettingRow {
            label: "Show each for"
            description: "Seconds before a notification bubble goes away. Hovering pauses it."
            NumberField {
              from: 2; to: 30
              value: Number(ui.s.noteSeconds)
              foreground: ui.fg
              accent: ui.accent
              fontFamily: ui.fontFamily
              onModified: function(v) { ui.set("noteSeconds", v) }
            }
          }

          SettingToggle { key: "holdWhileAway"; label: "Hold while I'm away"; description: "Keep them while she's asleep and sum them up in one bubble when you're back. Critical ones always show." }
          SettingToggle { key: "hideWhenSharing"; label: "Hide while screen sharing"; description: "Hide Eevee and her notifications while the screen is shared or recorded." }

          // ---- Assistant ----------------------------------------------------
          Section { text: "Assistant" }

          SettingToggle { key: "ai"; label: "Chat with Claude"; description: "Answer questions typed into her chat box (needs the claude CLI). Off, the box still takes /commands and \"open <app>\"." }

          SettingRow {
            label: "Model"
            description: "Faster models answer sooner; smarter ones dig deeper."
            Dropdown {
              width: Style.spacing.dropdownWidth
              showLabel: false
              fontFamily: ui.fontFamily
              options: ui.modelOptions
              value: String(ui.s.model)
              onChanged: function(v) { ui.set("model", v) }
            }
          }

          SettingToggle { key: "screenshots"; label: "Look at my screen when asked"; description: "Questions like \"what's on my screen?\" send her a screenshot of your current monitor. Only then." }

          SettingRow {
            label: "Memory"
            description: ui.memoryCount === 0
              ? "She remembers facts you tell her across chats. Nothing saved yet."
              : "She remembers " + ui.memoryCount + (ui.memoryCount === 1 ? " fact" : " facts") + " about you across chats."
            Row {
              spacing: Style.space(8)
              Button {
                text: "Forget all"
                bordered: true
                foreground: ui.fg
                accent: ui.accent
                fontFamily: ui.fontFamily
                visible: ui.memoryCount > 0
                onClicked: ui.brain(["forget"])
              }
              Button {
                text: "New chat"
                bordered: true
                foreground: ui.fg
                accent: ui.accent
                fontFamily: ui.fontFamily
                onClicked: ui.brain(["reset"])
              }
            }
          }

          // ---- Wellbeing & system ------------------------------------------
          Section { text: "Work" }

          Toggle {
            width: parent.width
            foreground: ui.fg
            accent: ui.accent
            fontFamily: ui.fontFamily
            label: "Tell me when long commands finish"
            description: "Adds one line to ~/.bashrc. When a terminal command runs past the time below and you've switched away, a notification says whether it worked; clicking it jumps back to that terminal. Applies to new terminals."
            opacity: hookSwitch.running ? 0.5 : 1
            checked: ui.hookState === "on"
            onClicked: {
              if (ui.hookState === "" || hookSwitch.running) return
              hookSwitch.command = ["bash", ui.buddy.brain, "cmdhook", ui.hookState === "on" ? "off" : "on"]
              hookSwitch.running = true
            }
          }

          SettingRow {
            label: "Long means at least"
            description: "Seconds a command must run before it counts."
            NumberField {
              from: 10; to: 3600; stepSize: 5
              value: Number(ui.s.longCommandSeconds)
              foreground: ui.fg
              accent: ui.accent
              fontFamily: ui.fontFamily
              onModified: function(v) { ui.set("longCommandSeconds", v) }
            }
          }

          Section { text: "Wellbeing" }

          SettingRow {
            label: "Break reminder"
            description: "Minutes of continuous work before she reminds you to take a break. 0 turns it off."
            NumberField {
              from: 0; to: 240; stepSize: 5
              value: Number(ui.s.breakMinutes)
              foreground: ui.fg
              accent: ui.accent
              fontFamily: ui.fontFamily
              onModified: function(v) { ui.set("breakMinutes", v) }
            }
          }

          SettingToggle { key: "lateNight"; label: "Late-night nudge"; description: "Suggest some rest if you're still working between 1 and 5 am." }
          SettingToggle { key: "reactions"; label: "React to the system"; description: "Hop when the CPU, memory, disk, heat or battery need attention, or a service fails." }

          // ---- Lock screen --------------------------------------------------
          Section { text: "Lock screen" }

          Toggle {
            width: parent.width
            foreground: ui.fg
            accent: ui.accent
            fontFamily: ui.fontFamily
            label: "Nap on the lock screen"
            description: ui.lockState === "missing"
              ? "Needs the Lock Designs plugin (io.github.smoothpixels.lock-designs)."
              : "Adds a \"Shelf + Eevee\" lock design with her asleep on it and switches to it. Off puts your previous design back."
            opacity: ui.lockState === "missing" || lockSwitch.running ? 0.5 : 1
            checked: ui.lockState === "on"
            onClicked: {
              if (ui.lockState === "missing" || ui.lockState === "" || lockSwitch.running) return
              lockSwitch.command = ["bash", ui.buddy.brain, "lockscreen", ui.lockState === "on" ? "off" : "on"]
              lockSwitch.running = true
            }
          }

          // ---- Try it -------------------------------------------------------
          Section { text: "Try it" }

          Row {
            spacing: Style.space(8)
            Button {
              text: "Send a test notification"
              bordered: true
              foreground: ui.fg
              accent: ui.accent
              fontFamily: ui.fontFamily
              onClicked: Quickshell.execDetached(["notify-send", "-a", "Eevee", "Hello from Eevee!", "This is how notifications look. Click the bubble to open the app that sent one."])
            }
            Button {
              text: "Pet her"
              bordered: true
              foreground: ui.fg
              accent: ui.accent
              fontFamily: ui.fontFamily
              onClicked: ui.buddy.pet()
            }
          }

          Text {
            width: parent.width
            topPadding: Style.space(10)
            wrapMode: Text.WordWrap
            color: ui.dim
            font.family: ui.fontFamily
            font.pixelSize: Style.font.caption
            text: "Click to chat · right-click for quick actions · middle-click to pet · drag to move · drop a file on her to have it explained.\n"
              + "In the chat: /attack, /focus [minutes], /remember <fact>, /forget, /evolve [form], /settings.\n"
              + "Settings are saved in ~/.config/omarchy/shell.json."
          }
        }
      }
    }
  }
}
