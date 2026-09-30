import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import Quickshell.Services.UPower
import Quickshell.Wayland
import qs.Commons

// Eevee desktop companion. Animated PMD sprite sheets (PMDCollab/SpriteCollab)
// walking along the bottom of the screen; now and then she evolves into an
// Eeveelution that fits the moment (the brain decides) and later reverts. All judgement lives in
// bin/eevee-brain: system sensing with cooldowns, notifications and
// Claude-backed chat. This file animates, renders and routes input.
//
// She never talks unprompted: system events only change what she does.
// The only text she shows on her own is desktop notifications (5 s each),
// which she delivers instead of Omarchy's popups.
//
//   left click    talk (type a question, Enter)
//   middle click  pet
//   hover         music controls when a player is open, else a quick status card
//   right click   quick actions: a strip of icons (explain a screen area or
//                 the clipboard, fix copied text, focus, settings)
//   drop a file   she reads it and explains it (logs, PDFs, images, code)
//   /attack       her signature move (also a quick action); events trigger
//                 moves of the matching type, e.g. plugging in the charger
//                 makes an Electric type use Thunderbolt
//   click bubble  open the notification's app (or dismiss an answer)
//   SUPER+ALT+E   talk from anywhere (omarchy-shell rafa.eevee talk)
//   /evolve [form], /devolve   in the chat box (or omarchy-shell rafa.eevee evolve <form>)
//   /focus [min], /focus off   hold notifications (except critical) until the end
//   /remember <fact>, /forget [text], /reset
//   /settings     the settings window (or omarchy-shell rafa.eevee settings,
//                 or omarchy-shell shell summon <plugin id> '{}')
//   "open spotify", "launch github.com"   launches (or focuses) apps and sites
Item {
  id: root

  // Injected by omarchy-shell.
  property var shell: null
  property var manifest: null
  readonly property string pluginId: root.manifest && root.manifest.id ? root.manifest.id : "rafa.desktop-buddy"

  // ---------------------------------------------------------------------
  // Settings, stored inline on this plugin's entry in shell.json (Omarchy's
  // convention). EeveeSettings.qml edits them; bin/eevee-brain reads the
  // same entry. Missing keys fall back to these defaults.
  // ---------------------------------------------------------------------
  readonly property var defaults: ({
    species: "eevee", shiny: "rare", screen: "follow", size: 3, wander: true,
    music: true, musicControls: true, hoverStatus: true, evolution: true, longCommandSeconds: 30, attacks: true, reduceMotion: false,
    benchmarks: true, benchmarkMs: 200, explainFailures: true, gitNudge: true,
    notifications: true, noteSeconds: 5, holdWhileAway: true, hideWhenSharing: true,
    ai: true, model: "claude-haiku-4-5", screenshots: true,
    reactions: true, breakMinutes: 50, lateNight: true, lateNightHour: 23,
    translateUbuntu: true
  })
  property var saved: ({})
  readonly property var settings: {
    var o = {}
    for (var k in root.defaults) o[k] = root.saved[k] !== undefined ? root.saved[k] : root.defaults[k]
    return o
  }

  function setSetting(key, value) {
    var next = {}
    for (var k in root.saved) next[k] = root.saved[k]
    next[key] = value
    root.saved = next
    if (root.shell && typeof root.shell.updateEntryInline === "function")
      root.shell.updateEntryInline(root.pluginId, next)
  }

  FileView {
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      var cfg = null
      try { cfg = JSON.parse(text()) } catch (e) { return }
      var list = cfg && Array.isArray(cfg.plugins) ? cfg.plugins : []
      for (var i = 0; i < list.length; i++) {
        if (!list[i] || list[i].id !== root.pluginId) continue
        var o = {}
        for (var k in list[i]) if (k !== "id") o[k] = list[i][k]
        root.saved = o
        return
      }
    }
  }

  EeveeSettings { id: settingsWindow; buddy: root }
  function openSettings() { root.closeChat(); settingsWindow.open() }
  // `omarchy-shell shell summon <id>` lands here.
  function open(payload) { root.openSettings() }

  // Eevee follows you to whichever monitor you've been working on for a
  // few seconds, unless the settings pin her to one.
  property string followedScreen: ""
  readonly property string screenName: root.settings.screen !== "follow"
    ? root.settings.screen : (root.followedScreen || root.focusedScreen)
  readonly property string focusedScreen: Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
  readonly property var hostScreen: {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++)
      if (screens[i].name === root.screenName) return screens[i]
    return screens.length > 0 ? screens[0] : null
  }
  readonly property int screenWidth: root.hostScreen ? root.hostScreen.width : 1280
  onFocusedScreenChanged: screenFollow.restart()
  property bool placed: false
  function place() {
    if (root.screenWidth < 200) return // screen not ready yet
    root.posX = root.placed
      ? Math.max(root.bodyWidth, Math.min(root.screenWidth - root.bodyWidth, root.posX))
      : root.screenWidth * 0.7
    root.placed = true
    root.targetX = root.posX
  }
  onScreenWidthChanged: root.place()
  Timer {
    id: screenFollow
    interval: 3000
    onTriggered: {
      if (!root.focusedScreen || root.focusedScreen === root.followedScreen) return
      if (root.pinned) { restart(); return }
      root.followedScreen = root.focusedScreen
    }
  }

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string brain: root.pluginDir + "/bin/eevee-brain"

  // ---------------------------------------------------------------------
  // Sprite sheets, one directory per form under forms/, with frame data in
  // forms/forms.json (tools/fetch-sprites.py). Durations are 1/60 s ticks.
  // 8-row sheets are ordered Down, then turning through the directions
  // (row 1 looks down-left, 2 right, 6 left, 7 down-right, as drawn); frames are centred on the body. Forms that lack an
  // animation (e.g. Sit) fall back to Idle.
  // ---------------------------------------------------------------------
  property var forms: ({})
  property string form: ""           // the brain's current form
  // What is drawn: always derived (so it can't go stale when the species
  // changes), except while the evolution flicker runs.
  property string flickerForm: ""
  readonly property string shownForm: root.evolving ? root.flickerForm : root.buddyForm
  property bool formSynced: false

  FileView {
    path: root.pluginDir + "/forms/forms.json"
    printErrors: true
    onLoaded: {
      try { root.forms = JSON.parse(text()) } catch (e) { console.warn("eevee: bad forms.json: " + e) }
    }
  }

  // Which Pokémon she is (forms/species.json lists the choices). Only Eevee
  // evolves; any other species is drawn as itself and ignores the brain's
  // evolution. Shiny comes from a daily 1-in-4096 roll in the brain, or the
  // settings force it on or off.
  property var speciesList: []
  FileView {
    path: root.pluginDir + "/forms/species.json"
    onLoaded: { try { root.speciesList = JSON.parse(text()) } catch (e) { root.speciesList = [] } }
  }
  readonly property string species: root.forms[root.settings.species] ? root.settings.species : "eevee"
  // Forms she can evolve into (forms/species.json): Eevee's eight, Charmander's
  // Charmeleon and Charizard, ... Empty for Snorlax and Gengar.
  readonly property var speciesForms: {
    for (var i = 0; i < root.speciesList.length; i++)
      if (root.speciesList[i].id === root.species) return root.speciesList[i].forms || []
    return []
  }
  readonly property bool evolves: root.speciesForms.length > 0
  readonly property string speciesLabel: {
    for (var i = 0; i < root.speciesList.length; i++)
      if (root.speciesList[i].id === root.species) return root.speciesList[i].label
    return root.pretty(root.species)
  }
  readonly property string buddyForm: root.speciesForms.indexOf(root.form) !== -1 ? root.form : root.species
  property bool shinyToday: false
  readonly property bool shiny: root.settings.shiny === "always" || (root.settings.shiny !== "never" && root.shinyToday)

  readonly property var fallbackSpec: ({ w: 24, h: 32, rows: 8, d: [40, 16], loop: true, foot: 5, bodyW: 21 })
  function specOf(formName, name) {
    var f = root.forms[formName]
    return f ? (f[name] || f.Idle) : root.fallbackSpec
  }
  function hasAnim(formName, name) { var f = root.forms[formName]; return !!(f && f[name]) }
  function pretty(name) { return name.charAt(0).toUpperCase() + name.slice(1) }

  readonly property int pixelScale: Math.max(2, Math.min(4, Number(root.settings.size) || 3))
  readonly property int bodyWidth: root.specOf(root.shownForm, "Idle").bodyW * root.pixelScale

  property string anim: "Idle"
  property int frame: 0
  property bool facingRight: true
  readonly property var animSpec: root.specOf(root.shownForm, root.anim)
  readonly property string animFile: root.hasAnim(root.shownForm, root.anim) ? root.anim : "Idle"
  readonly property int animRow: {
    if (root.animSpec.rows === 1) return 0
    if (root.anim === "Walk") return root.facingRight ? 2 : 6
    return root.facingRight ? 7 : 1 // PMD row 1 looks down-left, row 7 down-right
  }
  onShownFormChanged: root.frame = 0

  signal animFinished(string name)

  function play(name) {
    if (root.anim === name && root.animSpec.loop) return
    root.anim = name
    root.frame = 0
    frameTimer.interval = Math.round(root.specOf(root.shownForm, name).d[0] * 1000 / 60)
    frameTimer.restart()
  }

  Timer {
    id: frameTimer
    repeat: true
    running: true
    interval: 600
    onTriggered: {
      var spec = root.animSpec
      var next = Math.min(root.frame, spec.d.length - 1) + 1
      if (next >= spec.d.length) {
        if (!spec.loop) { running = false; root.animFinished(root.anim); return }
        next = 0
      }
      root.frame = next
      interval = Math.round(spec.d[next] * 1000 / 60)
    }
  }

  // ---------------------------------------------------------------------
  // Behaviour: a tiny state machine. Chat and speech pin Eevee in place;
  // otherwise it wanders, sits, sniffs around, and naps while you're away.
  // ---------------------------------------------------------------------
  property real posX: 0 // placed once the screen size is known
  property real targetX: root.posX
  property bool walking: false
  // Activity is event-driven (Wayland idle notifications, which also honour
  // inhibitors such as a playing video): asleep after 4 idle minutes; five
  // idle minutes end a work streak; ten or more count as a break.
  readonly property bool userAway: idleAway.isIdle
  property real streakStart: Date.now()
  property real idleSince: 0
  property bool backFromBreak: false
  IdleMonitor { id: idleShort; timeout: 60 }
  IdleMonitor { id: idleAway; timeout: 240 }
  IdleMonitor {
    timeout: 300
    onIsIdleChanged: {
      if (isIdle) { root.idleSince = Date.now() - 300000; return }
      if (Date.now() - root.idleSince >= 600000) root.backFromBreak = true
      root.streakStart = Date.now()
    }
  }
  property bool thinking: false
  property bool chatOpen: false
  property bool evolving: false
  readonly property bool pinned: root.chatOpen || root.thinking || root.speechVisible || root.evolving || root.attacking
    || root.controlsVisible || root.actionsOpen || root.dropHover
  readonly property real walkSpeed: 1.6
  property int friendship: 0 // 0-10, from the brain; livelier when higher
  readonly property bool musicPlaying: {
    if (!root.settings.music) return false
    var players = Mpris.players.values
    for (var i = 0; i < players.length; i++)
      if (players[i] && players[i].isPlaying) return true
    return false
  }
  onMusicPlayingChanged: if (!root.pinned && !root.walking) root.settle()

  // ---------------------------------------------------------------------
  // Music controls: hovering Eevee while a media player is open shows the
  // track with previous / play-pause / next. The one playing wins, then
  // Spotify, then whichever player is there. She holds still meanwhile.
  // ---------------------------------------------------------------------
  // The look every popup shares: a quiet card with a hairline border.
  component Card: Rectangle {
    radius: Math.max(8, Style.cornerRadius)
    color: Util.alpha(Color.popups.background, 0.96)
    border.width: 1
    border.color: Util.alpha(Color.popups.text, 0.12)
  }

  // A glyph button for the music controls.
  component MusicButton: Text {
    id: mb
    property bool active: true
    signal activated()
    textFormat: Text.PlainText
    color: !mb.active ? Util.alpha(Color.popups.text, 0.3) : mbHover.hovered ? Color.accent : Color.popups.text
    font.family: Style.font.family
    font.pixelSize: 20
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    HoverHandler { id: mbHover; cursorShape: mb.active ? Qt.PointingHandCursor : Qt.ArrowCursor }
    TapHandler { enabled: mb.active; onTapped: mb.activated() }
  }

  readonly property var player: {
    if (!root.settings.musicControls) return null
    var players = Mpris.players.values, best = null
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p) continue
      if (p.isPlaying) return p
      if (!best || /spotify/i.test(String(p.identity || ""))) best = p
    }
    return best
  }
  // Hover card: music controls when a player is open, otherwise (if enabled)
  // a quick status snapshot fetched from the brain only while you hover.
  readonly property bool showMusic: root.player !== null
  readonly property bool controlsVisible: (root.showMusic || root.settings.hoverStatus) && !root.hidden
    && (dragArea.containsMouse || controlsHover.hovered || controlsLinger.running)
    && !root.chatOpen && !root.thinking && !root.speechVisible && !root.evolving && !root.actionsOpen
    && !dragArea.pressed
  property var hoverStatus: null
  property real hoverStatusAt: 0
  onControlsVisibleChanged: {
    if (root.controlsVisible && !root.showMusic && Date.now() - root.hoverStatusAt > 5000 && !hoverProc.running)
      hoverProc.running = true
  }
  Process {
    id: hoverProc
    command: ["bash", root.brain, "hover"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.hoverStatus = JSON.parse(String(text || "")) } catch (e) { return }
        root.hoverStatusAt = Date.now()
      }
    }
  }

  // A little hop when the song changes.
  Connections {
    target: root.player
    ignoreUnknownSignals: true
    function onTrackTitleChanged() { if (!root.walking) root.react("happy") }
  }

  // ---------------------------------------------------------------------
  // Quick actions: right-click opens a small strip of icons above her head
  // with the few things only she can do. Omarchy's own keys already cover
  // screenshots, colour picking, emoji and launching, and left-click opens
  // the chat, so anything that is just a sentence ("remind me in 10", "why
  // is it slow?") belongs there rather than here. What stays is the work
  // that needs the pointer or the clipboard under it. The strip closes
  // after an action, a click on her, or once the pointer has been away
  // from it for a moment.
  // ---------------------------------------------------------------------
  property bool actionsOpen: false
  readonly property var quickActions: [
    { icon: "󰆞", label: "Explain an area", fn: "look", ai: true },
    { icon: "󰅌", label: "Explain clipboard", fn: "clip", ai: true },
    { icon: "󰓆", label: "Fix clipboard text", fn: "fix", ai: true },
    // A history clock, not a second clipboard: with the labels gone the
    // glyph is all you get, and two clipboards read as the same button.
    { icon: "󰋚", label: "Clipboard history", fn: "clipboard" },
    { icon: "󰔟", label: root.focusing ? "End focus" : "Focus 25 min", fn: "focus" },
    { icon: "󰒓", label: "Settings", fn: "settings" }
  ]
  readonly property var visibleActions: root.quickActions.filter(function(a) { return !a.ai || root.settings.ai })
  // The menu and the chat box replace each other: only one is ever open.
  function toggleActions() {
    root.actionsOpen = !root.actionsOpen
    if (root.actionsOpen) {
      if (root.chatOpen) root.closeChat()
      root.dismissSpeech(); root.walking = false; root.play("LookUp"); actionsIdle.restart()
    }
  }
  function runAction(a) {
    root.actionsOpen = false
    if (a.fn === "focus") { if (root.focusing) root.endFocus(); else root.startFocus(25); root.react("happy") }
    else if (a.fn === "settings") root.openSettings()
    else if (a.fn === "clip") root.runBrain(["clip", "explain"])
    else if (a.fn === "fix") root.runBrain(["clip", "fix"])
    else if (a.fn === "clipboard") clipboardDelay.restart()
    else if (a.fn === "look") lookDelay.restart()
  }
  // The area picker starts once the menu has gone; the capture happens
  // before she starts thinking, so her bubble isn't in the picture.
  Timer { id: lookDelay; interval: 200; onTriggered: if (!lookProc.running) lookProc.running = true }

  // The clipboard history the rest of the system opens. The bar widget's own
  // panel comes up at the pointer, right next to her, so try that first; if
  // it isn't installed, `omarchy-shell <target> <method>` exits non-zero and
  // we fall back to Omarchy's own (the same thing SUPER+CTRL+V toggles).
  // Delayed a moment so the strip is gone before the overlay takes focus.
  Timer {
    id: clipboardDelay
    interval: 180
    onTriggered: Quickshell.execDetached(["bash", "-c",
      "omarchy-shell iamcheyan.clipboard open >/dev/null 2>&1 || omarchy-menu-clipboard"])
  }
  Process {
    id: lookProc
    readonly property string file: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/eevee/look.png"
    command: ["bash", "-c", "mkdir -p \"${1%/*}\" && g=$(slurp) && grim -g \"$g\" \"$1\"", "_", file]
    onExited: function(code) { if (code === 0) root.runBrain(["look", lookProc.file]) }
  }
  Timer {
    id: actionsIdle
    interval: 1800
    onTriggered: if (root.actionsOpen) { if (actionMenuHover.hovered || dragArea.containsMouse) restart(); else root.actionsOpen = false }
  }

  // ---------------------------------------------------------------------
  // Drop a file on her and she explains it.
  // ---------------------------------------------------------------------
  property bool dropHover: false
  function explainFile(url) {
    var path = decodeURIComponent(String(url).replace(/^file:\/\//, ""))
    if (path === "") return
    if (!root.settings.ai) { root.react("think"); return }
    root.runBrain(["ask", "I dropped this file on you: " + path + "\nRead it, then tell me briefly what it is and what matters in it. If it's a log or has errors, explain them and the likely fix."])
  }
  // A moment's grace to move the pointer from Eevee up to the controls.
  Timer { id: controlsLinger; interval: 700 }
  Connections {
    target: dragArea
    function onContainsMouseChanged() { if (!dragArea.containsMouse) controlsLinger.restart() }
  }

  function settle() {
    if (root.attacking) return // the attack settles her when it's done
    root.walking = false
    if (root.thinking) root.play("Nod")
    else if (root.userAway) root.play("Sleep")
    else if (root.musicPlaying && !root.settings.reduceMotion) root.play("Nod") // bopping along
    else root.play("Idle")
  }

  function pickNextAction() {
    if (root.pinned || root.userAway || dragArea.pressed) { root.settle(); return }
    // Focus mode: she sits quietly by your side instead of wandering.
    if (root.focusing) { root.play("Sit"); behaviourTimer.restartIn(20000); return }
    var r = Math.random()
    if (root.musicPlaying && r < 0.35) {
      root.play("Nod")
      behaviourTimer.restartIn(6000 + Math.random() * 6000)
      return
    }
    if (Math.random() < root.friendship * 0.025) {
      root.play("Pose")
      behaviourTimer.restartIn(3000 + Math.random() * 4000)
      return
    }
    // Reduce motion: no wandering, bopping or posing, just the odd sit.
    if (root.settings.reduceMotion) {
      root.play(Math.random() < 0.3 ? "Sit" : "Idle")
      behaviourTimer.restartIn(8000 + Math.random() * 8000)
      return
    }
    if (!root.settings.wander && r < 0.55) r = 0.55 + Math.random() * 0.45
    if (r < 0.55) {
      var maxX = root.screenWidth - root.bodyWidth
      var span = 120 + Math.random() * 500
      var dest = root.posX + (Math.random() < 0.5 ? -span : span)
      root.targetX = Math.max(root.bodyWidth, Math.min(maxX, dest))
      root.facingRight = root.targetX >= root.posX
      root.walking = true
      root.play("Walk")
    } else if (r < 0.7) {
      root.play("Sit")
    } else if (r < 0.8) {
      root.play("LookUp")
    } else if (r < 0.87) {
      root.play("Eat")
    } else {
      root.facingRight = !root.facingRight
      root.play("Idle")
    }
    if (!root.walking) behaviourTimer.restartIn(3000 + Math.random() * 5000)
  }

  onAnimFinished: function(name) {
    // One-shot animations hold their last frame; Hop and Pose return to idle.
    if (name === "Hop" || name === "Pose") root.settle()
    else if (name === "Charge" && root.attacking) root.releaseAttack()
  }

  // ---------------------------------------------------------------------
  // Attacks. Every sprite set has a type; events call for a type, and a
  // Pokémon of that type answers with its move: Charge, then Shoot (or a
  // Tackle dash for Normal types) while attackFx draws the effect. No text.
  // ---------------------------------------------------------------------
  readonly property var typesOf: ({
    eevee: ["normal"], vaporeon: ["water"], jolteon: ["electric"], flareon: ["fire"],
    espeon: ["psychic"], umbreon: ["dark"], leafeon: ["grass"], glaceon: ["ice"], sylveon: ["fairy"],
    pikachu: ["electric"], charmander: ["fire"], bulbasaur: ["grass"], squirtle: ["water"],
    psyduck: ["water", "psychic"], munchlax: ["normal"], snorlax: ["normal"], gengar: ["ghost"],
    charmeleon: ["fire"], charizard: ["fire"], ivysaur: ["grass"], venusaur: ["grass"],
    wartortle: ["water"], blastoise: ["water"], raichu: ["electric"], golduck: ["water", "psychic"]
  })
  readonly property var types: root.typesOf[root.shownForm] || ["normal"]
  // Which event calls for which type. "any" means every Pokémon joins in.
  readonly property var eventTypes: ({
    charger: ["electric"], hot: ["fire"], refresh: ["water"], morning: ["grass"], cool: ["ice"],
    spooky: ["ghost", "dark"], pet: ["fairy"], answer: ["psychic"], command: ["any"]
  })
  readonly property var typeColors: ({
    electric: "#ffe14d", fire: "#ff7b29", water: "#4fb8ff", grass: "#6fd36f", ice: "#a8f0ff",
    psychic: "#f06bd0", dark: "#5b2a86", ghost: "#8b5cf6", fairy: "#ff9fd6", normal: "#ffffff"
  })
  property bool attacking: false
  property string attackType: "normal"
  property real attackDx: 0 // Tackle's dash
  property real attackSeed: 0

  // Does this event make the current Pokémon attack? Returns the type to
  // attack with, or "".
  function attackFor(event) {
    var want = root.eventTypes[event]
    if (!want || !root.settings.attacks) return ""
    for (var i = 0; i < want.length; i++) {
      if (want[i] === "any") return root.types[0]
      if (root.types.indexOf(want[i]) !== -1) return want[i]
    }
    return ""
  }

  // An event happened: attack if it fits her type, otherwise the usual
  // small reaction (if any).
  function onEvent(event, fallbackMood) {
    var t = root.attackFor(event)
    if (t !== "") root.attack(t)
    else if (fallbackMood && root.settings.reactions) root.react(fallbackMood)
  }

  function attack(type) {
    if (root.settings.reduceMotion) return
    if (root.attacking || root.chatOpen || root.evolving || root.hidden || root.actionsOpen) return
    root.attackType = type || root.types[0]
    root.attackSeed = Math.random() * 1000
    root.attacking = true
    root.walking = false
    root.play("Charge")
    attackWatchdog.restart()
  }
  // If anything interrupts the move (an evolution, a drag), don't stay stuck.
  Timer {
    id: attackWatchdog
    interval: 4000
    onTriggered: if (root.attacking) { attackRun.stop(); root.attacking = false; root.attackDx = 0; attackFx.t = 0; root.settle() }
  }

  function releaseAttack() {
    root.play(root.attackType === "normal" ? "Attack" : "Shoot")
    attackRun.restart()
  }

  NumberAnimation {
    id: attackRun
    target: attackFx
    property: "t"
    from: 0; to: 1
    duration: root.attackType === "electric" ? 900 : 1100
    onFinished: { attackWatchdog.stop(); root.attacking = false; root.attackDx = 0; attackFx.t = 0; root.settle() }
  }

  // Plugging in the charger.
  property bool wasOnBattery: false // set at startup, then tracked by hand
  Connections {
    target: UPower
    function onOnBatteryChanged() {
      if (root.wasOnBattery && !UPower.onBattery) root.onEvent("charger", "happy")
      root.wasOnBattery = UPower.onBattery
    }
  }

  Timer {
    id: behaviourTimer
    function restartIn(ms) { interval = ms; restart() }
    interval: 2500
    running: true
    onTriggered: root.pickNextAction()
  }

  Timer {
    interval: 16
    repeat: true
    running: root.walking
    onTriggered: {
      if (root.pinned) { root.settle(); return }
      var delta = root.targetX - root.posX
      if (Math.abs(delta) <= root.walkSpeed) {
        root.posX = root.targetX
        root.settle()
        behaviourTimer.restartIn(1500 + Math.random() * 4000)
        return
      }
      root.posX += Math.sign(delta) * root.walkSpeed
    }
  }

  onUserAwayChanged: {
    if (!root.pinned) root.settle()
    if (!root.userAway && !root.focusing) root.releaseHeld("While you were away")
  }
  onPinnedChanged: {
    if (root.pendingEvolution && !root.chatOpen && !root.thinking && !root.evolving) {
      var p = root.pendingEvolution
      root.pendingEvolution = null
      evolveDelay.pending = p
      evolveDelay.restart()
    }
    if (!root.pinned) behaviourTimer.restartIn(2500)
  }

  // ---------------------------------------------------------------------
  // Evolution: white silhouette, old/new forms flicker faster and faster,
  // a flash, then the new form hops out. Deferred while you're chatting.
  // ---------------------------------------------------------------------
  property var pendingEvolution: null
  property real whiteness: 0
  property string evolveFrom: ""
  property string evolveTarget: ""

  // `asked` marks an evolution you typed or triggered yourself (/evolve,
  // /devolve, the IPC). Reduce motion silences the evolutions she decides on
  // by herself, but not one you just asked to see.
  function evolveTo(target, message, asked) {
    if (!root.forms[target] || target === root.form) return
    if (root.evolving || root.chatOpen || root.thinking) {
      if (!root.evolving) root.pendingEvolution = { target: target, message: message, asked: asked === true }
      return
    }
    var from = root.shownForm
    root.form = target
    // Only animate a real change of what's on screen.
    if (root.buddyForm !== from) root.playEvolution(from, root.buddyForm, asked === true)
  }

  // The evolution sequence (white silhouette, flicker, flash).
  function playEvolution(from, to, asked) {
    if (root.settings.reduceMotion && !asked) return // shownForm simply follows
    root.flickerForm = from
    root.evolveFrom = from
    root.evolveTarget = to
    root.walking = false
    root.evolving = true
    root.play("Idle")
    evolveSequence.restart()
  }

  SequentialAnimation {
    id: evolveSequence
    NumberAnimation { target: root; property: "whiteness"; from: 0; to: 1; duration: 900; easing.type: Easing.InQuad }
    ScriptAction { script: { flicker.interval = 420; flicker.restart() } }
  }

  Timer {
    id: flicker
    repeat: true
    onTriggered: {
      root.flickerForm = root.flickerForm === root.evolveTarget ? root.evolveFrom : root.evolveTarget
      interval = Math.round(interval * 0.84)
      if (interval < 40) {
        stop()
        root.flickerForm = root.evolveTarget
        evolveFinish.restart()
      }
    }
  }

  SequentialAnimation {
    id: evolveFinish
    ScriptAction { script: evolveFlash.restart() }
    NumberAnimation { target: root; property: "whiteness"; to: 0; duration: 800; easing.type: Easing.OutQuad }
    ScriptAction {
      script: {
        root.evolving = false
        root.react("happy")
      }
    }
  }

  Timer {
    id: evolveDelay
    property var pending: null
    interval: 800
    onTriggered: if (pending) { root.evolveTo(pending.target, pending.message, pending.asked); pending = null }
  }

  function requestEvolve(target) {
    if (!root.evolves || evolveProc.running || root.evolving) return
    evolveProc.command = ["bash", "-c", "\"$0\" evolve \"$1\" && \"$0\" form", root.brain, String(target || "")]
    evolveProc.running = true
  }

  Process {
    id: evolveProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").trim().split("\n")
        // Everything through requestEvolve is something you asked for.
        if (lines.length >= 2) root.evolveTo(lines[lines.length - 1].trim(), lines[0], true)
      }
    }
    stderr: StdioCollector {
      onStreamFinished: if (String(text || "").trim() !== "") root.react("think")
    }
  }

  // ---------------------------------------------------------------------
  // Speech
  // ---------------------------------------------------------------------
  property string speechText: ""
  property bool speechVisible: false
  property var speechQueue: []
  // The notification the bubble is showing (null for an answer); clicking
  // the bubble acts on it like clicking Omarchy's popup would.
  property var speechNote: null
  property int noteCount: 0
  property string speechTitle: "" // the notification's app, drawn as a header
  readonly property string speechCommand: {
    // Offer to copy the first command-looking snippet in an answer.
    var spans = root.speechText.match(/`[^`\n]{2,200}`/g) || []
    for (var j = 0; j < spans.length; j++) {
      var s = spans[j].slice(1, -1).trim()
      if (/ /.test(s) && /^[a-z][\w.+-]*( |$)/.test(s)) return s
    }
    var lines = root.speechText.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var l = lines[i].trim()
      if (/^(sudo |omarchy |yay |pacman |systemctl |journalctl |hyprctl |uv |git |paru |flatpak )/.test(l)) return l
    }
    return ""
  }

  function moodAnim(mood) {
    if (root.settings.reduceMotion) return mood === "sleepy" ? "Sleep" : "Idle"
    return mood === "alert" ? "Hop" : mood === "happy" ? "Hop" : mood === "think" ? "LookUp"
      : mood === "sleepy" ? "Sleep" : mood === "calm" ? "Sit" : "Pose"
  }

  function say(text, mood, note) {
    text = String(text || "").trim()
    if (text === "") return
    // Notifications wait their turn rather than cover the bubble that's up.
    if (root.chatOpen || root.thinking || (note && root.speechVisible)) {
      root.speechQueue = root.speechQueue.concat([{ text: text, mood: mood, note: note || null }])
      return
    }
    root.walking = false
    root.speechText = text
    root.speechNote = note || null
    root.noteCount = note ? (note.count || 1) : 0
    root.speechTitle = note ? root.noteTitle(note, root.noteCount) : ""
    root.speechVisible = true
    if (!root.attacking) root.play(root.moodAnim(mood || "happy"))
    // Notifications leave after 5 s; answers stay longer the longer they
    // are. Hovering pauses either.
    speechTimer.interval = note ? root.noteDuration : Math.min(60000, Math.max(7000, text.length * 70))
    speechTimer.restart()
  }

  function dismissSpeech() {
    root.speechVisible = false
    root.speechNote = null
    speechTimer.stop()
    if (root.speechQueue.length > 0) {
      var next = root.speechQueue[0]
      root.speechQueue = root.speechQueue.slice(1)
      queueTimer.pending = next
      queueTimer.restart()
    }
  }

  Timer {
    id: speechTimer
    onTriggered: if (bubbleHover.hovered) restart(); else root.dismissSpeech()
  }
  Timer {
    id: queueTimer
    property var pending: null
    interval: 600
    onTriggered: if (pending) { root.say(pending.text, pending.mood, pending.note); pending = null }
  }

  // ---------------------------------------------------------------------
  // Notifications. While Eevee is up, Omarchy's popups are silenced (its Do
  // Not Disturb, so everything still lands in the notification history) and
  // bin/eevee-notify.py hands each notification to her instead. A burst from
  // one app folds into one bubble. While you're away or in focus mode they
  // are held (critical ones excepted) and summed up in one bubble after.
  // A fullscreen window covers Eevee, so Omarchy's popups come back while
  // one is up; while the screen is shared or recorded she hides and they go
  // quietly to the history.
  // ---------------------------------------------------------------------
  readonly property int noteDuration: Math.max(1, Number(root.settings.noteSeconds) || 5) * 1000
  // A real fullscreen window (mode 2; maximized ones don't cover her) on
  // the workspace showing on Eevee's monitor. Read from the shell's own
  // Hyprland IPC data, refreshed on focus and fullscreen events: no process
  // is started.
  readonly property bool fullscreen: {
    var mons = Hyprland.monitors.values, ws = null
    for (var i = 0; i < mons.length; i++)
      if (mons[i].name === root.screenName && mons[i].activeWorkspace) ws = mons[i].activeWorkspace.id
    if (ws === null) return false
    var tops = Hyprland.toplevels.values
    for (var j = 0; j < tops.length; j++) {
      var o = tops[j].lastIpcObject
      if (o && o.workspace && o.workspace.id === ws && Number(o.fullscreen || 0) >= 2) return true
    }
    return false
  }
  property real focusUntil: 0
  readonly property bool focusing: root.focusUntil > 0
  property var heldNotes: []

  // Screen shared or recorded, and the settings say to hide then.
  readonly property bool hidden: root.sharing && root.settings.hideWhenSharing
  readonly property bool wantDnd: root.settings.notifications && !root.fullscreen
  onWantDndChanged: root.syncDnd()
  function syncDnd() {
    Quickshell.execDetached(["omarchy-shell", "-q", "notifications", "setDnd", root.wantDnd ? "on" : "off"])
  }
  Component.onCompleted: { root.place(); root.syncDnd(); Hyprland.refreshToplevels(); root.wasOnBattery = UPower.onBattery }
  Component.onDestruction: Quickshell.execDetached(["omarchy-shell", "-q", "notifications", "setDnd", "off"])

  onHiddenChanged: if (root.hidden) { root.closeChat(); root.dismissSpeech() }

  function appLabel(app) {
    return app === "omarchy-action" ? "Omarchy" : app === "notify-send" ? "" : String(app || "")
  }

  function noteTitle(n, count) {
    var head = root.appLabel(n.app)
    return count > 1 ? (head ? head + " · " : "") + count + " new" : head
  }

  function noteText(n) {
    var lines = [n.summary]
    if (n.body && n.body !== n.summary) lines.push(n.body.length > 160 ? n.body.slice(0, 157) + "…" : n.body)
    return lines.filter(function(l) { return !!l }).join("\n")
  }

  function onNotification(n) {
    if (root.fullscreen) return
    if (n.app === "Terminal" && !root.hidden) root.onEvent("command", "") // Omarchy's popup shows over the fullscreen app
    // Omarchy still pops these up under Do Not Disturb; take them over once
    // its popup exists (it's inserted a moment after the call).
    if (n.bypass && !root.hidden)
      Quickshell.execDetached(["bash", "-c", "sleep 0.7; omarchy-shell -q notifications dismiss \"$1\"", "eevee", n.summary])
    if (root.hidden) return
    if (((root.userAway && root.settings.holdWhileAway) || root.focusing) && n.urgency < 2) {
      root.heldNotes = root.heldNotes.concat([n])
      return
    }
    root.showNote(n)
  }

  function showNote(n) {
    if (root.speechVisible && root.speechNote && root.speechNote.app === n.app) {
      root.noteCount += 1
      root.speechNote = n
      root.speechTitle = root.noteTitle(n, root.noteCount)
      root.speechText = root.noteText(n)
      speechTimer.restart()
      return
    }
    root.say(root.noteText(n), n.urgency >= 2 ? "alert" : "think", n)
  }

  // One bubble for everything held back, e.g. "While you were away:
  // 3 from Discord, 1 from Slack". Clicking it opens the latest one's app.
  function releaseHeld(why) {
    var held = root.heldNotes
    root.heldNotes = []
    if (held.length === 0) return
    if (held.length === 1) { root.showNote(held[0]); return }
    var counts = ({}), order = []
    for (var i = 0; i < held.length; i++) {
      var a = root.appLabel(held[i].app) || "other"
      if (!(a in counts)) { counts[a] = 0; order.push(a) }
      counts[a]++
    }
    var parts = order.map(function(a) { return counts[a] + " from " + a })
    var last = held[held.length - 1]
    root.say(why + ": " + parts.join(", ") + "\nLatest: " + last.summary, "think",
      { app: "", summary: last.summary, desktop: last.desktop || last.app, exec: last.exec, count: 1 })
  }

  function openNote(n) {
    var argv = null
    try { argv = n.exec ? JSON.parse(n.exec) : null } catch (e) { argv = null }
    if (Array.isArray(argv) && argv.length > 0 && argv.every(function(a) { return typeof a === "string" })
        && argv[0] !== "" && argv[0].charAt(0) !== "-") {
      Quickshell.execDetached(argv)
      return
    }
    var target = n.desktop || n.app
    if (target && target !== "notify-send" && target !== "omarchy-action")
      Quickshell.execDetached(["omarchy-hyprland-focus-app", target])
  }

  function startFocus(minutes) {
    minutes = Math.max(1, Math.min(480, Math.round(Number(minutes) || 25)))
    root.focusUntil = Date.now() + minutes * 60000
    focusEnd.interval = minutes * 60000
    focusEnd.restart()
    root.dismissSpeech()
    root.walking = false
    root.play("Sit")
  }

  function endFocus() {
    if (!root.focusing) return
    root.focusUntil = 0
    focusEnd.stop()
    root.react("happy")
    root.releaseHeld("During focus")
  }

  Timer { id: focusEnd; onTriggered: root.endFocus() }

  Process {
    id: notifyWatch
    command: ["python3", root.pluginDir + "/bin/eevee-notify.py"]
    running: root.settings.notifications
    stdout: SplitParser {
      onRead: function(line) {
        var n = null
        try { n = JSON.parse(line) } catch (e) { return }
        root.onNotification(n)
      }
    }
  }
  Timer {
    interval: 5000
    running: root.settings.notifications && !notifyWatch.running
    onTriggered: notifyWatch.running = true
  }

  // Screen state is event-driven, nothing polls. Fullscreen: see above.
  // Recorders are started from a menu or region picker, i.e. a layer
  // event, so other programs' layers opening or closing trigger one pgrep;
  // the 20 s sense tick re-checks as a backstop. Portal screen shares
  // appear as PipeWire nodes, watched live.
  property bool recording: false
  readonly property bool portalSharing: {
    var nodes = Pipewire.nodes.values
    for (var i = 0; i < nodes.length; i++)
      if (nodes[i] && String(nodes[i].name || "").indexOf("xdph") === 0) return true
    return false
  }
  readonly property bool sharing: root.recording || root.portalSharing

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var n = event.name, data = String(event.data || "")
      if (n === "fullscreen" || n === "activewindowv2" || n === "workspacev2")
        toplevelRefresh.restart()
      else if ((n === "openlayer" || n === "closelayer") && data !== "rafa-desktop-buddy"
               && data.indexOf("omarchy-keyboard-panel") !== 0)
        screenCheck.restart()
    }
  }
  Timer { id: toplevelRefresh; interval: 200; onTriggered: Hyprland.refreshToplevels() }
  Timer { id: screenCheck; interval: 400; onTriggered: root.checkScreen() }
  function checkScreen() { if (!screenProc.running) screenProc.running = true }

  Process {
    id: screenProc
    command: ["pgrep", "-x", "gpu-screen-reco|wf-recorder|obs"]
    onExited: function(code) { root.recording = code === 0 }
  }

  // Unprompted events (alerts, pets, evolution) only animate; speech bubbles
  // are reserved for answers to something you asked.
  function react(mood) {
    if (root.pinned) return
    root.walking = false
    root.play(root.moodAnim(mood || "happy"))
    behaviourTimer.restartIn(4000)
  }

  // A pet is something you did with your own hand, so she always answers it
  // with a real animation. Reduce motion is there to stop her fidgeting on
  // her own; it should not make her ignore you. The cycle never repeats an
  // animation twice in a row, because play() skips a looping animation that
  // is already running -- so the tenth pet still reads as a reaction.
  readonly property var petAnims: ["Hop", "Pose", "Hop", "Nod", "Hop", "LookUp"]
  property int petCount: 0

  function pet() {
    if (root.evolving) return
    // A Fairy-type flourish when her type calls for one; attack() bows out
    // under reduce motion, so only take that branch when it will show.
    if (!root.settings.reduceMotion && root.attackFor("pet") !== "") {
      root.attack("fairy")
    } else if (!root.attacking) {
      root.walking = false
      root.play(root.petAnims[root.petCount++ % root.petAnims.length])
      if (!root.pinned) behaviourTimer.restartIn(4000)
    }
    // Enough affection evolves Eevee into Sylveon.
    Quickshell.execDetached(["bash", root.brain, "pet"])
  }

  // ---------------------------------------------------------------------
  // Brain processes
  // ---------------------------------------------------------------------
  function openChat() {
    root.actionsOpen = false
    root.dismissSpeech()
    root.chatOpen = true
    root.walking = false
    root.play("Idle")
    focusTimer.restart()
  }

  function closeChat() {
    root.chatOpen = false
    chatInput.text = ""
  }

  function ask(question) {
    question = String(question || "").trim()
    root.closeChat()
    if (question === "") return
    if (question === "/settings") { root.openSettings(); return }
    if (question === "/attack") { root.attack(""); return }
    if (question === "/reset" || question === "/new") {
      Quickshell.execDetached(["bash", root.brain, "reset"])
      root.react("happy")
      return
    }
    var focus = question.match(/^\/focus\s*(\w*)$/i)
    if (focus) {
      if (/^(off|stop|end)$/i.test(focus[1])) root.endFocus()
      else root.startFocus(focus[1] || 25)
      return
    }
    // /here reads the assignment in this folder; /english rewrites what you
    // copied. Both answer in the bubble like any other question.
    if (question === "/here") { root.runBrain(["here", ""]); return }
    if (question === "/english") { root.runBrain(["clip", "english"]); return }
    var mem = question.match(/^\/(remember|forget)\s*(.*)$/i)
    if (mem) {
      Quickshell.execDetached(["bash", root.brain, mem[1].toLowerCase(), mem[2]])
      root.react("happy")
      return
    }
    var evo = question.match(/^\/(evolve|devolve)\s*(\w*)$/i)
    if (evo) { root.requestEvolve(evo[1].toLowerCase() === "devolve" ? root.species : evo[2].toLowerCase()); return }
    // "open X" skips the AI when X names an installed app; vaguer requests
    // ("open something to edit photos") fall through to Claude in the brain.
    var launch = question.match(/^(?:open|launch|start|run|abre|abrir|abra|inicia)\s+(.+)$/i)
    if (launch) { root.runBrain(["open", launch[1]], "open"); return }
    root.runBrain(["ask", question])
  }

  function launch(app) { root.runBrain(["open", String(app || "")], "open") }


  function runBrain(args, mode) {
    if (askProc.running) { root.react("think"); return }
    askProc.mode = mode || ""
    root.dismissSpeech()
    root.thinking = true
    root.walking = false
    root.play("Nod")
    askProc.command = ["bash", root.brain].concat(args)
    askProc.running = true
  }

  Process {
    id: askProc
    property string mode: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.thinking = false
        var out = String(text || "").trim()
        // A launched app is its own answer; only words that matter get a bubble.
        if (out !== "") { root.say(out, "happy"); if (askProc.mode !== "open") root.onEvent("answer", "") }
        else root.react(askProc.mode === "open" ? "happy" : "think")
      }
    }
  }

  function sense() {
    if (senseProc.running) return
    senseProc.command = ["bash", root.brain, "sense", idleShort.isIdle ? "0" : "1",
      String(Math.floor((Date.now() - root.streakStart) / 60000)), root.backFromBreak ? "1" : "0"]
    root.backFromBreak = false
    senseProc.running = true
  }

  // Lines from the brain: "mood<TAB>message", plus form/friend/shiny.
  function handleBrainLines(text) {
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          if (lines[i] === "") continue
          var tab = lines[i].indexOf("\t")
          var mood = tab < 0 ? lines[i] : lines[i].slice(0, tab)
          var msg = tab < 0 ? "" : lines[i].slice(tab + 1)
          if (mood === "friend") { root.friendship = parseInt(msg) || 0; continue }
          if (mood === "form") {
            var tab2 = msg.indexOf("\t")
            var target = tab2 < 0 ? msg : msg.slice(0, tab2)
            var why = tab2 < 0 ? "" : msg.slice(tab2 + 1)
            if (!root.formSynced) {
              // First tick after (re)load: adopt the form silently.
              root.formSynced = true
              if (root.forms[target]) root.form = target
            } else if (target !== root.form) {
              root.evolveTo(target, why)
            }
            continue
          }
          if (mood === "shiny") { root.shinyToday = msg === "1"; continue }
          if (root.eventTypes[mood]) {
            // Type events: an attack when it fits; hot and spooky still get a hop otherwise.
            root.onEvent(mood, mood === "hot" || mood === "spooky" ? "alert" : "")
            continue
          }
          if (root.settings.reactions) root.react(mood)
        }
  }

  Process {
    id: senseProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.handleBrainLines(String(text || "")) }
  }

  Timer {
    interval: 20000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: { root.sense(); root.checkScreen() }
  }

  Timer {
    id: focusTimer
    interval: 60
    onTriggered: chatInput.forceActiveFocus()
  }

  IpcHandler {
    target: "rafa.eevee"
    function talk(): void { if (root.chatOpen) root.closeChat(); else root.openChat() }
    function close(): void { root.closeChat(); root.dismissSpeech(); root.actionsOpen = false; settingsWindow.shown = false }
    function pet(): void { root.pet() }
    function ask(question: string): void { root.ask(question) }
    function say(text: string): void { root.say(text, "happy") }
    function evolve(form: string): void { root.requestEvolve(form) }
    function devolve(): void { root.requestEvolve(root.species) }
    function launch(app: string): void { root.launch(app) }
    function settings(): void { root.openSettings() }
    // Change a setting the way the settings window does, e.g. `set species pikachu`.
    function set(key: string, value: string): string {
      if (!(key in root.defaults)) return "unknown setting"
      var v = value === "true" ? true : value === "false" ? false : (value !== "" && !isNaN(Number(value)) ? Number(value) : value)
      root.setSetting(key, v)
      return "ok"
    }
    function actions(): void { root.toggleActions() }
    // Attack with a type ("electric", "fire", …) or, empty, her own.
    function attack(type: string): void { root.attack(type) }
    function event(name: string): void { root.onEvent(name, "") }
    // Run one quick action by (part of) its name, e.g. "area", "fix".
    function action(name: string): string {
      var q = String(name || "").toLowerCase()
      for (var i = 0; i < root.visibleActions.length; i++)
        if (q !== "" && root.visibleActions[i].label.toLowerCase().indexOf(q) !== -1) { root.runAction(root.visibleActions[i]); return root.visibleActions[i].label }
      return "unknown"
    }
    function focusMode(minutes: string): void { if (/^(off|stop|end)$/i.test(minutes)) root.endFocus(); else root.startFocus(minutes) }
    function state(): string {
      return JSON.stringify({ anim: root.anim, x: Math.round(root.posX), walking: root.walking, thinking: root.thinking,
        chatOpen: root.chatOpen, speaking: root.speechVisible, away: root.userAway, queued: root.speechQueue.length,
        asking: askProc.running, form: root.form, shown: root.shownForm, evolving: root.evolving,
        forms: Object.keys(root.forms).length, screen: root.screenName, fullscreen: root.fullscreen,
        sharing: root.sharing, recording: root.recording, portalSharing: root.portalSharing,
        species: root.species, attacking: root.attacking, pinned: root.pinned, hoverCard: root.controlsVisible,
        settingsOpen: settingsWindow.shown,
        shiny: root.shiny,
        actionsOpen: root.actionsOpen, hoverCard: root.controlsVisible, focusing: root.focusing, held: root.heldNotes.length, music: root.musicPlaying,
        friendship: root.friendship, note: root.speechNote ? root.speechNote.app : null,
        notifyWatch: notifyWatch.running })
    }
  }

  // ---------------------------------------------------------------------
  // Window: one transparent strip along the bottom edge. Only Eevee, the
  // bubble and the chat box take input, so everything else clicks through.
  // ---------------------------------------------------------------------
  PanelWindow {
    id: panel
    screen: root.hostScreen
    // Hidden while the screen is shared or recorded.
    visible: root.hostScreen !== null && !root.hidden
    anchors { bottom: true; left: true; right: true }
    implicitHeight: 420
    color: "transparent"
    WlrLayershell.namespace: "rafa-desktop-buddy"
    // Top, not Overlay: fullscreen apps (video, games) cover Eevee.
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: root.chatOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    exclusiveZone: 0

    mask: Region {
      item: hitBox
      Region { item: bubble.visible ? bubble : null }
      Region { item: chatBox.visible ? chatBox : null }
      Region { item: musicBar.visible ? musicBar : null }
      Region { item: actionMenu.visible ? actionMenu : null }
    }

    // Ground line: Eevee's feet rest here.
    readonly property real groundY: height - 6
    readonly property real popupX: {
      var w = Math.max(bubble.width, chatBox.visible ? chatBox.width : 0)
      return Math.max(8, Math.min(width - w - 8, root.posX - w / 2))
    }

    Item {
      id: sprite
      readonly property var spec: root.animSpec
      width: spec.w * root.pixelScale
      height: spec.h * root.pixelScale
      x: root.posX - width / 2 + root.attackDx + attackFx.jitter
      y: panel.groundY - (height / 2 + spec.foot * root.pixelScale)
      clip: true
      layer.enabled: root.whiteness > 0
      layer.smooth: false
      layer.effect: MultiEffect {
        colorization: root.whiteness
        colorizationColor: "white"
        brightness: root.whiteness
      }

      Image {
        source: root.forms[root.shownForm] ? "forms/" + root.shownForm + (root.shiny ? "/shiny/" : "/") + root.animFile + ".png" : ""
        smooth: false
        mipmap: false
        width: sourceSize.width * root.pixelScale
        height: sourceSize.height * root.pixelScale
        x: -root.frame * sprite.width
        y: -root.animRow * sprite.height
      }
    }

    // Stable hit box around the body, independent of the frame size.
    Item {
      id: hitBox
      width: root.bodyWidth + 12
      height: 28 * root.pixelScale
      x: root.posX - width / 2
      y: panel.groundY - height

      MouseArea {
        id: dragArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        cursorShape: Qt.PointingHandCursor
        property real pressX: 0
        property real startPos: 0
        property bool dragged: false
        onPressed: function(e) {
          pressX = mapToItem(null, e.x, 0).x; startPos = root.posX; dragged = false
          // Quick actions open on the press itself, not the release.
          if (e.button === Qt.RightButton) root.toggleActions()
        }
        onPositionChanged: function(e) {
          if (!(pressedButtons & Qt.LeftButton)) return
          var dx = mapToItem(null, e.x, 0).x - pressX
          if (!dragged && Math.abs(dx) < 6) return
          if (!dragged) { dragged = true; root.walking = false; root.play("Hop") }
          root.posX = Math.max(root.bodyWidth / 2, Math.min(root.screenWidth - root.bodyWidth / 2, startPos + dx))
          root.facingRight = dx >= 0
        }
        onReleased: if (dragged) behaviourTimer.restartIn(3000)
        onClicked: function(e) {
          if (dragged || e.button === Qt.RightButton) return
          root.actionsOpen = false
          if (e.button === Qt.MiddleButton) root.pet()
          else if (e.button === Qt.RightButton) root.toggleActions()
          else if (root.chatOpen) root.closeChat()
          else root.openChat()
        }
      }

      DropArea {
        anchors.fill: parent
        keys: ["text/uri-list"]
        onEntered: { root.dropHover = true; root.walking = false; root.play("LookUp") }
        onExited: { root.dropHover = false; root.settle() }
        onDropped: function(drop) {
          root.dropHover = false
          if (drop.hasUrls && drop.urls.length > 0) {
            drop.acceptProposedAction()
            root.explainFile(drop.urls[0])
          }
        }
      }
    }

    // Music controls on hover.
    Card {
      id: musicBar
      visible: root.controlsVisible
      readonly property var p: root.player
      width: (root.showMusic ? musicRow.implicitWidth : statusCol.implicitWidth) + 24
      height: (root.showMusic ? musicRow.implicitHeight : statusCol.implicitHeight) + 16
      x: Math.max(8, Math.min(panel.width - width - 8, root.posX - width / 2))
      y: hitBox.y - height - 10
      HoverHandler { id: controlsHover }

      Column {
        id: statusCol
        visible: !root.showMusic
        anchors.centerIn: parent
        spacing: 2
        readonly property var st: root.hoverStatus
        Text {
          textFormat: Text.PlainText
          text: statusCol.st
            ? "CPU " + statusCol.st.cpu + "% · RAM " + statusCol.st.mem + "% · " + statusCol.st.temp + "°C · disk " + statusCol.st.disk + "%"
            : "…"
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        Text {
          visible: text !== ""
          textFormat: Text.PlainText
          text: statusCol.st && statusCol.st.battery !== ""
            ? "Battery " + statusCol.st.battery + "% · " + String(statusCol.st.charging).toLowerCase() : ""
          color: Util.alpha(Color.popups.text, 0.7)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        Text {
          visible: text !== ""
          textFormat: Text.PlainText
          text: statusCol.st && statusCol.st.reminder ? "󰢌 " + statusCol.st.reminder : ""
          color: Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        Text {
          visible: root.focusing
          textFormat: Text.PlainText
          text: "󰔟 Focusing · " + Math.max(1, Math.round((root.focusUntil - Date.now()) / 60000)) + " min left"
          color: Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      Row {
        id: musicRow
        visible: root.showMusic
        anchors.centerIn: parent
        spacing: 12

        Column {
          anchors.verticalCenter: parent.verticalCenter
          Text {
            width: Math.min(implicitWidth, 200)
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: musicBar.p ? (musicBar.p.trackTitle || musicBar.p.identity || "Music") : ""
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
          Text {
            visible: text !== ""
            width: Math.min(implicitWidth, 200)
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: musicBar.p ? String(musicBar.p.trackArtist || "") : ""
            color: Util.alpha(Color.popups.text, 0.6)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        MusicButton {
          text: "󰒮"
          active: !!musicBar.p && musicBar.p.canGoPrevious
          onActivated: musicBar.p.previous()
        }
        MusicButton {
          text: musicBar.p && musicBar.p.isPlaying ? "󰏤" : "󰐊"
          active: !!musicBar.p && musicBar.p.canTogglePlaying
          onActivated: musicBar.p.togglePlaying()
        }
        MusicButton {
          text: "󰒭"
          active: !!musicBar.p && musicBar.p.canGoNext
          onActivated: musicBar.p.next()
        }
      }
    }

    // Quick actions: one row of icons, nothing else. Five glyphs the hand
    // learns in a day; a label under them only made the strip resize as
    // the pointer crossed it.
    Card {
      id: actionMenu
      visible: root.actionsOpen
      readonly property int cell: 30
      color: Util.alpha(Color.popups.background, 0.82)
      border.color: Util.alpha(Color.popups.text, 0.08)
      width: actionRow.implicitWidth + 12
      height: cell + 12
      x: Math.max(8, Math.min(panel.width - width - 8, root.posX - width / 2))
      y: hitBox.y - height - 8
      HoverHandler { id: actionMenuHover }

      Row {
        id: actionRow
        anchors.centerIn: parent
        spacing: 0

        Repeater {
          model: root.visibleActions
          delegate: Rectangle {
            required property var modelData
            width: actionMenu.cell
            height: actionMenu.cell
            radius: height / 2
            color: actionMouse.containsMouse ? Util.alpha(Color.accent, 0.2) : "transparent"

            Text {
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: modelData.icon
              color: actionMouse.containsMouse ? Color.accent : Util.alpha(Color.popups.text, 0.8)
              font.family: Style.font.family
              font.pixelSize: 16
            }
            MouseArea {
              id: actionMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.runAction(modelData)
            }
          }
        }
      }
    }

    // Attack effects, centred on her body; drawn only while attacking.
    Item {
      id: attackFx
      property real t: 0
      readonly property string type: root.attackType
      readonly property real dir: root.facingRight ? 1 : -1
      readonly property color col: root.typeColors[type] || "white"
      readonly property real jitter: root.attacking && type === "electric" && t > 0 && t < 0.8 ? (Math.sin(t * 157) * 2) : 0
      visible: root.attacking && t > 0
      x: root.posX
      y: hitBox.y + hitBox.height * 0.55
      width: 0; height: 0
      onTChanged: {
        if (type === "normal") root.attackDx = Math.sin(Math.PI * Math.min(1, t * 1.6)) * 46 * dir
        if (type === "electric") bolts.requestPaint()
      }

      function rnd(i, k) { var v = Math.sin((root.attackSeed + i * 12.9898 + k * 78.233)) * 43758.5453; return v - Math.floor(v) }
      function ease(x) { return 1 - Math.pow(1 - Math.max(0, Math.min(1, x)), 3) }

      // Glow behind her in the move's colour.
      Rectangle {
        readonly property real g: Math.sin(Math.PI * attackFx.t)
        width: 50 + 60 * g; height: width; radius: width / 2
        x: -width / 2; y: -height / 2
        color: attackFx.col
        opacity: (attackFx.type === "dark" ? 0.35 : 0.22) * g
      }

      // Electric: lightning from above, redrawn every frame.
      Canvas {
        id: bolts
        visible: attackFx.type === "electric"
        width: 340; height: 360
        x: -width / 2; y: -height + 40
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var t = attackFx.t
          if (t <= 0 || t > 0.85) return
          var n = 3
          for (var b = 0; b < n; b++) {
            if (Math.random() < 0.25) continue // flicker
            var x = width / 2 + (b - 1) * 70 + (Math.random() - 0.5) * 30
            var y = 0
            ctx.beginPath()
            ctx.moveTo(x, y)
            while (y < height - 40) {
              y += 18 + Math.random() * 22
              x += (Math.random() - 0.5) * 44
              ctx.lineTo(x, Math.min(y, height - 40))
            }
            ctx.lineCap = "round"; ctx.lineJoin = "round"
            ctx.strokeStyle = "rgba(255, 225, 77, 0.35)"; ctx.lineWidth = 9; ctx.stroke()
            ctx.strokeStyle = "#fff7c2"; ctx.lineWidth = 3; ctx.stroke()
          }
        }
      }

      // Everything else: particles computed from t, per type.
      Repeater {
        model: 18
        delegate: Item {
          id: part
          required property int index
          readonly property var p: attackFx.particle(index, attackFx.t)
          visible: !!p && p.o > 0.01
          x: p ? p.x : 0
          y: p ? p.y : 0
          Rectangle {
            visible: !!part.p && !part.p.text
            width: part.p ? part.p.w : 0
            height: part.p ? part.p.h : 0
            x: -width / 2; y: -height / 2
            radius: part.p ? part.p.r : 0
            rotation: part.p ? part.p.rot : 0
            color: part.p && part.p.ring ? "transparent" : (part.p ? part.p.c : "white")
            border.width: part.p && part.p.ring ? part.p.bw : 0
            border.color: part.p ? part.p.c : "white"
            opacity: part.p ? part.p.o : 0
          }
          Text {
            visible: !!part.p && !!part.p.text
            text: part.p && part.p.text ? part.p.text : ""
            anchors.centerIn: parent
            color: part.p ? part.p.c : "white"
            opacity: part.p ? part.p.o : 0
            font.pixelSize: part.p ? part.p.w : 10
            rotation: part.p ? part.p.rot : 0
          }
        }
      }

      // One particle of the effect: position relative to her centre, size,
      // colour, opacity. null = unused for this type.
      function particle(i, t) {
        var d = dir, ty = type, p
        if (t <= 0) return null
        if (ty === "fire") {                        // Flamethrower
          var s0 = i / 18 * 0.55, q = (t - s0) / 0.45
          if (q <= 0 || q >= 1) return null
          var heat = ["#fff3b0", "#ffd166", "#ff9f1c", "#ff5400", "#c1121f"][Math.min(4, Math.floor(q * 5))]
          p = 12 + q * 26
          return { x: d * (26 + q * 190), y: -16 + (rnd(i, 1) - 0.5) * 22 * q - q * 14, w: p, h: p, r: p / 2, c: heat, o: 1 - q * 0.9, rot: 0 }
        }
        if (ty === "water") {                       // Water Gun
          var s1 = i / 18 * 0.5, q1 = (t - s1) / 0.5
          if (q1 <= 0 || q1 >= 1) return null
          return { x: d * (24 + q1 * 200), y: -24 - 70 * q1 + 110 * q1 * q1 + (rnd(i, 2) - 0.5) * 10, w: 10, h: 12, r: 6,
                   c: rnd(i, 3) > 0.5 ? "#4fb8ff" : "#bfe9ff", o: 1 - q1 * 0.6, rot: 0 }
        }
        if (ty === "grass") {                       // Razor Leaf
          if (i >= 8) return null
          var s2 = i / 8 * 0.4, q2 = (t - s2) / 0.6
          if (q2 <= 0 || q2 >= 1) return null
          return { x: d * (20 + q2 * 210), y: -30 + Math.sin(q2 * 9 + i) * 16 + (i % 3 - 1) * 14, w: 18, h: 9, r: 5,
                   c: i % 2 ? "#6fd36f" : "#3fa34d", o: 1 - Math.max(0, q2 - 0.7) * 3, rot: q2 * 900 + i * 40 }
        }
        if (ty === "ice") {                         // Ice Beam
          if (i === 0) {
            var len = 220 * ease(t / 0.35)
            return { x: d * (22 + len / 2), y: -22, w: len, h: 8, r: 4, c: "#dffbff", o: t < 0.75 ? 1 : (1 - t) * 4, rot: 0 }
          }
          if (i > 10) return null
          var q3 = (t - 0.3) / 0.7
          if (q3 <= 0) return null
          return { x: d * (40 + i * 20), y: -22 + (rnd(i, 4) - 0.5) * 30 * ease(q3), w: 9, h: 9, r: 1, c: "#a8f0ff",
                   o: 1 - q3, rot: 45 + q3 * 180 }
        }
        if (ty === "psychic" || ty === "dark") {    // Confusion / Dark Pulse
          if (i >= 5) return null
          var q4 = (t - i * 0.12) / 0.55
          if (q4 <= 0 || q4 >= 1) return null
          var rr = 20 + q4 * 170
          return { x: 0, y: -20, w: rr, h: rr * (ty === "dark" ? 1 : 0.6), r: rr / 2, ring: true, bw: ty === "dark" ? 6 : 3,
                   c: ty === "dark" ? (i % 2 ? "#2a0f45" : "#7c3aed") : (i % 2 ? "#f06bd0" : "#c084fc"), o: 1 - q4, rot: 0 }
        }
        if (ty === "ghost") {                       // Shadow Ball
          if (i > 6) return null
          var grow = ease(t / 0.35), fly = Math.max(0, (t - 0.35) / 0.55)
          if (fly >= 1) return null
          if (i === 0) {
            var sz = 16 + 30 * grow
            return { x: d * (26 + fly * 200), y: -26, w: sz, h: sz, r: sz / 2, c: "#3b0764", o: 0.95, rot: 0 }
          }
          var a = i / 6 * Math.PI * 2 + t * 12, rad = (18 + 20 * grow)
          return { x: d * (26 + fly * 200) + Math.cos(a) * rad * 0.7, y: -26 + Math.sin(a) * rad * 0.7, w: 10, h: 10, r: 5,
                   c: "#a78bfa", o: 0.8, rot: 0 }
        }
        if (ty === "fairy") {                       // Dazzling Gleam
          if (i >= 14) return null
          var q5 = ease(t / 0.8)
          var ang = i / 14 * Math.PI * 2 + rnd(i, 5)
          return { x: Math.cos(ang) * q5 * 120, y: -24 + Math.sin(ang) * q5 * 80, w: 14 + rnd(i, 6) * 10, text: "✦",
                   c: i % 3 ? "#ff9fd6" : "#fff0fa", o: 1 - Math.max(0, t - 0.6) * 2.5, rot: t * 180 }
        }
        if (ty === "normal") {                      // Tackle: impact at the peak of the dash
          if (i >= 8) return null
          var q6 = (t - 0.3) / 0.45
          if (q6 <= 0 || q6 >= 1) return null
          var ang2 = i / 8 * Math.PI * 2
          return { x: d * 60 + Math.cos(ang2) * q6 * 44, y: -20 + Math.sin(ang2) * q6 * 44, w: 9 - q6 * 5, h: 9 - q6 * 5,
                   r: 5, c: "#ffffff", o: 1 - q6, rot: 0 }
        }
        return null                                  // electric: the canvas does it
      }
    }

    // Evolution flash.
    Rectangle {
      id: flash
      width: 90; height: 90; radius: 45
      color: "white"
      x: root.posX - width / 2
      y: hitBox.y + hitBox.height / 2 - height / 2
      opacity: 0
      scale: 0.2
      ParallelAnimation {
        id: evolveFlash
        NumberAnimation { target: flash; property: "opacity"; from: 0.95; to: 0; duration: 900; easing.type: Easing.OutQuad }
        NumberAnimation { target: flash; property: "scale"; from: 0.3; to: 3.2; duration: 900; easing.type: Easing.OutCubic }
      }
    }

    // Speech bubble. Deliberately slight: a translucent slip of text that
    // sits over the wallpaper rather than a panel that covers it. No tail,
    // no frame -- she is right underneath it, so nothing has to point.
    Card {
      id: bubble
      visible: root.speechVisible || root.thinking
      readonly property int maxW: 290
      readonly property int pad: 9
      radius: Math.max(6, Style.cornerRadius)
      color: Util.alpha(Color.popups.background, 0.78)
      border.color: Util.alpha(Color.popups.text, 0.07)
      width: Math.min(maxW, Math.max(bubbleText.implicitWidth, bubbleTitle.visible ? bubbleTitle.implicitWidth : 0,
        copyRow.visible ? copyRow.implicitWidth : 0) + pad * 2)
      height: Math.min(200, bubbleCol.implicitHeight + pad * 2)
      x: panel.popupX
      y: hitBox.y - height - 8

      HoverHandler { id: bubbleHover }

      Flickable {
        id: bubbleFlick
        anchors.fill: parent
        anchors.margins: bubble.pad
        contentHeight: bubbleCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: bubbleCol
          width: bubbleFlick.width
          spacing: 3

          Text {
            id: bubbleTitle
            visible: !root.thinking && root.speechTitle !== ""
            width: Math.min(implicitWidth, bubble.maxW - bubble.pad * 2)
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: root.speechTitle
            color: Util.alpha(Color.popups.text, 0.45)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            id: bubbleText
            width: Math.min(implicitWidth, bubble.maxW - bubble.pad * 2)
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            text: root.thinking ? "Hmm" + ".".repeat(thinkDots.n) : root.speechText
            color: Util.alpha(Color.popups.text, 0.92)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            lineHeight: 1.15
          }

          // Copy the command in the answer: a small pill under the text.
          Rectangle {
            id: copyRow
            visible: !root.thinking && root.speechCommand !== ""
            implicitWidth: Math.min(copyLabel.implicitWidth + 12, bubble.maxW - bubble.pad * 2)
            width: implicitWidth
            height: copyLabel.implicitHeight + 5
            radius: height / 2
            color: copyHover.hovered ? Util.alpha(Color.accent, 0.16) : Util.alpha(Color.popups.text, 0.05)
            HoverHandler { id: copyHover; cursorShape: Qt.PointingHandCursor }
            TapHandler {
              onTapped: {
                Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(root.speechCommand) + " | wl-copy"])
                copied.restart()
              }
            }
            Timer { id: copied; interval: 1500 }
            Text {
              id: copyLabel
              anchors.centerIn: parent
              width: Math.min(implicitWidth, parent.width - 12)
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: (copied.running ? "󰄬 Copied" : "󰆏 ") + (copied.running ? "" : root.speechCommand)
              color: copyHover.hovered || copied.running ? Color.accent : Util.alpha(Color.popups.text, 0.75)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      // Click the text (not the copy row) to dismiss; a notification also
      // opens its app.
      TapHandler {
        enabled: !root.thinking
        onTapped: function(ev) {
          if (copyRow.visible && ev.position.y > bubble.height - copyRow.height - bubble.pad - 4) return
          if (root.speechNote) root.openNote(root.speechNote)
          root.dismissSpeech()
        }
      }

      Timer {
        id: thinkDots
        property int n: 1
        interval: 400
        repeat: true
        running: root.thinking
        onTriggered: n = n % 3 + 1
      }
    }

    // Chat box.
    Card {
      id: chatBox
      visible: root.chatOpen
      readonly property int pad: 8
      // Just the prompt and room for the caret; it widens as you type and
      // stops at the bubble's width. No placeholder -- the caret says it.
      width: Math.min(bubble.maxW, Math.max(96,
        chatPrompt.width + chatMetrics.width + pad * 2 + 10))
      height: Math.max(26, chatInput.implicitHeight + pad)
      // Centred on her, not on panel.popupX: that reserves the bubble's
      // width, which would leave this much narrower box sitting to the left
      // of it. Clamped so it stays on screen at the edges.
      x: Math.max(8, Math.min(panel.width - width - 8, root.posX - width / 2))
      y: hitBox.y - height - 8
      radius: Math.max(6, Style.cornerRadius)
      color: Util.alpha(Color.popups.background, 0.78)
      border.color: Util.alpha(Color.accent, 0.3)

      // Measured off to the side, so the width never depends on the width.
      TextMetrics {
        id: chatMetrics
        font: chatInput.font
        text: chatInput.text
      }

      Text {
        id: chatPrompt
        x: chatBox.pad
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: "›"
        color: Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall + 1
      }

      TextInput {
        id: chatInput
        anchors.fill: parent
        anchors.leftMargin: chatPrompt.x + chatPrompt.width + 5
        anchors.rightMargin: chatBox.pad
        verticalAlignment: TextInput.AlignVCenter
        clip: true
        selectByMouse: true
        color: Color.popups.text
        selectionColor: Util.alpha(Color.accent, 0.35)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        onAccepted: root.ask(text)
        Keys.onEscapePressed: root.closeChat()
      }
    }
  }
}
