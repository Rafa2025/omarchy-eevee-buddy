// name: Shelf + Eevee
// description: The Shelf design, with Eevee napping on it
//
// Shelf (below) plus the Eevee desktop buddy, asleep on top of the
// shelf as whichever Pokémon and form is on the desktop right now
// (~/.local/state/eevee/sprite, shiny included), drawn from
// the plugin's own sprite sheets. If the plugin is gone she just isn't there.
//
// SmoothPixels original. The wallpaper takes the whole screen; a slim
// translucent shelf floats above the bottom edge with your avatar and name
// on the left, the password field in the middle, and the clock and date on
// the right. Nothing else, so the wallpaper is the picture.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

DesignBase {
  id: lock
  inputItem: field.input

  readonly property real u: Math.min(width, height) / 100
  readonly property color ink: Color.lock.text
  readonly property color dim: lock.withAlpha(Color.lock.text, 0.55)

  Rectangle { anchors.fill: parent; color: Color.background }

  Image {
    anchors.fill: parent
    source: lock.loadBackground ? lock.fileUrl(lock.backgroundPath) : ""
    fillMode: Image.PreserveAspectCrop
    asynchronous: true
    cache: false
    sourceSize.width: width
    sourceSize.height: height
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    onClicked: { lock.wakeRequested(); lock.forcePasswordFocus() }
    onPositionChanged: lock.wakeRequested()
  }

  Rectangle {
    id: shelf
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Math.round(lock.u * 3)
    width: Math.round(Math.min(lock.width - lock.u * 6, lock.u * 120))
    height: Math.round(lock.u * 8.5)
    radius: Math.max(Style.cornerRadius, 16)
    color: lock.withAlpha(Color.lock.background, 0.82)
    border.width: 1
    border.color: lock.withAlpha(Color.lock.border, 0.2)

    Row {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Math.round(lock.u * 2)
      spacing: Math.round(lock.u * 1.4)
      Avatar {
        anchors.verticalCenter: parent.verticalCenter
        lock: lock
        width: Math.round(lock.u * 5.2)
        shadow: false
      }
      Column {
        anchors.verticalCenter: parent.verticalCenter
        spacing: Math.round(lock.u * 0.3)
        Text {
          text: lock.userName
          color: lock.ink
          font.family: lock.displayFont
          font.pixelSize: Math.round(lock.u * 1.9)
          font.weight: Font.DemiBold
        }
        Text {
          text: lock.greeting()
          color: lock.dim
          font.family: lock.displayFont
          font.pixelSize: Math.round(lock.u * 1.3)
        }
      }
    }

    PasswordField {
      id: field
      lock: lock
      anchors.centerIn: parent
      width: Math.round(shelf.width * 0.36)
      height: Math.round(lock.u * 4.4)
      color: lock.withAlpha(Color.background, 0.4)
      radius: Math.max(Style.cornerRadius, 12)
      placeholder: "Enter password"
    }

    Column {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.rightMargin: Math.round(lock.u * 2.4)
      spacing: Math.round(lock.u * 0.3)
      Text {
        anchors.right: parent.right
        text: lock.clock("HH:mm")
        renderType: Text.CurveRendering
        color: lock.ink
        font.family: lock.displayFont
        font.pixelSize: Math.round(lock.u * 3.4)
        font.weight: Font.DemiBold
      }
      Text {
        anchors.right: parent.right
        text: Qt.formatDate(lock.now, "dddd, d MMMM")
        color: lock.dim
        font.family: lock.displayFont
        font.pixelSize: Math.round(lock.u * 1.3)
      }
    }
  }

  // ---- Eevee, asleep on the shelf -------------------------------------
  // Filled in by `eevee-brain lockscreen on` when it installs this design.
  readonly property string buddyDir: "@BUDDY_DIR@"
  property var buddyForms: ({})
  property string buddyForm: "eevee"
  property bool buddyShiny: false

  FileView {
    path: lock.buddyDir + "/forms/forms.json"
    onLoaded: { try { lock.buddyForms = JSON.parse(text()) } catch (e) { lock.buddyForms = ({}) } }
  }
  FileView {
    path: Quickshell.env("HOME") + "/.local/state/eevee/sprite"
    onLoaded: {
      var p = String(text() || "").trim().split("\t")
      if (p[0]) lock.buddyForm = p[0]
      lock.buddyShiny = p[1] === "1"
    }
  }

  Item {
    id: eevee
    readonly property string sheet: lock.buddyForms[lock.buddyForm] ? lock.buddyForm : "eevee"
    readonly property var spec: lock.buddyForms[sheet] ? lock.buddyForms[sheet].Sleep : null
    readonly property int px: Math.max(2, Math.round(lock.u * 0.5))
    property int frame: 0
    visible: spec !== null && spec !== undefined
    width: visible ? spec.w * px : 0
    height: visible ? spec.h * px : 0
    clip: true
    // Feet resting on the shelf's top edge, between the field and the clock.
    x: Math.round(shelf.x + shelf.width * 0.76 - width / 2)
    y: Math.round(shelf.y + px - (height / 2 + (visible ? spec.foot * px : 0)))

    Image {
      source: eevee.visible ? "file://" + lock.buddyDir + "/forms/" + eevee.sheet + (lock.buddyShiny ? "/shiny/" : "/") + "Sleep.png" : ""
      smooth: false
      mipmap: false
      width: sourceSize.width * eevee.px
      height: sourceSize.height * eevee.px
      x: -eevee.frame * eevee.width
    }

    Timer {
      running: eevee.visible
      repeat: true
      interval: eevee.visible ? Math.round(eevee.spec.d[eevee.frame % eevee.spec.d.length] * 1000 / 60) : 1000
      onTriggered: eevee.frame = (eevee.frame + 1) % eevee.spec.d.length
    }
  }

  Text {
    id: zzz
    visible: eevee.visible
    text: "z z Z"
    color: lock.dim
    font.family: lock.displayFont
    font.pixelSize: Math.round(lock.u * 2)
    font.bold: true
    x: eevee.x + eevee.width * 0.7
    property real drift: 0
    y: eevee.y - height * 0.2 - drift
    opacity: 1 - drift / (lock.u * 4)
    NumberAnimation on drift {
      from: 0; to: lock.u * 3
      duration: 2600
      loops: Animation.Infinite
      running: zzz.visible
    }
  }
}
