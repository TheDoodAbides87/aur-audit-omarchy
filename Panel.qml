import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar icon + popup panel for aur-audit. The icon shows the last system scan
// and lights up when an install was blocked since you last looked. Every
// action opens a floating terminal through run.sh, so scans and AI reviews
// behave exactly as they do on the command line (including the AI cost
// prompt). status.py reads the saved reports; neither script needs root.
Panel {
  id: root
  moduleName: "thedoodabides87.aur-audit"
  ipcTarget: "thedoodabides87.aur-audit"

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string statusScript: pluginDir + "/status.py"
  readonly property string runScript: pluginDir + "/run.sh"
  readonly property string githubUrl: "https://github.com/TheDoodAbides87/aur-audit"
  // Same rule run.sh and status.py enforce: pacman package names only.
  readonly property var packagePattern: /^[a-z0-9@_+][a-z0-9@._+-]*$/

  readonly property int staleDays: Math.max(1, parseInt(setting("staleScanDays", 7), 10) || 7)

  property var status: null
  property real now: Date.now() / 1000
  property string packageError: ""

  // ---------- Derived state ----------
  readonly property bool loaded: status !== null
  readonly property bool installed: loaded && status.installed === true
  readonly property var lastScan: loaded ? status.lastScan : null
  readonly property int newBlocks: loaded ? (status.newBlocks || 0) : 0
  readonly property var reports: loaded ? (status.reports || []) : []
  readonly property int scanAgeDays: lastScan ? Math.floor((now - lastScan.time) / 86400) : -1
  readonly property bool scanStale: !lastScan || scanAgeDays >= staleDays

  // "missing" > "alert" (urgent colour) > "stale" (dimmed) > "clean".
  readonly property string level: {
    if (!loaded) return "stale"
    if (!installed) return "missing"
    if (newBlocks > 0 || (lastScan && lastScan.serious > 0)) return "alert"
    if (scanStale) return "stale"
    return "clean"
  }

  readonly property string icon: {
    if (level === "missing") return String.fromCodePoint(0xF099E)  // shield-off
    if (level === "alert") return String.fromCodePoint(0xF0ECC)  // shield-alert
    if (level === "stale") return String.fromCodePoint(0xF0499)  // shield-outline
    return String.fromCodePoint(0xF0565)  // shield-check
  }

  readonly property string headline: {
    if (!loaded) return "Loading"
    if (!installed) return "aur-audit is not installed"
    if (newBlocks > 0) return newBlocks === 1 ? "Blocked an install" : ("Blocked " + newBlocks + " installs")
    if (!lastScan) return "No system scan yet"
    if (lastScan.serious > 0) return lastScan.serious + " serious finding" + (lastScan.serious === 1 ? "" : "s")
    if (scanStale) return "No scan in " + scanAgeDays + " days"
    if (lastScan.check > 0) return "Clean · " + lastScan.check + " to check"
    return "Clean"
  }

  readonly property string subline: {
    if (!installed) return ""
    if (!lastScan) return "Run a system scan to get a baseline"
    return "Last system scan " + ago(lastScan.time)
  }

  readonly property string tooltip: "AUR Audit: " + headline

  // ---------- Helpers ----------
  function ago(epoch) {
    var s = Math.max(0, now - epoch)
    if (s < 90) return "just now"
    if (s < 3600) return Math.round(s / 60) + " min ago"
    if (s < 86400) return Math.round(s / 3600) + " h ago"
    var d = Math.round(s / 86400)
    return d === 1 ? "yesterday" : d + " days ago"
  }

  function reportIcon(kind) {
    if (kind === "blocked") return String.fromCodePoint(0xF0026)  // alert
    if (kind === "system-scan") return String.fromCodePoint(0xF0D9A)  // shield-search
    return String.fromCodePoint(0xF06A9)  // robot
  }

  function reportIsAlarming(r) {
    if (r.kind === "blocked") return true
    if (r.kind === "system-scan") return r.serious > 0
    return r.verdict === "MALICIOUS" || r.verdict === "SIGNS OF COMPROMISE"
  }

  function refresh() {
    now = Date.now() / 1000
    if (!statusProc.running) statusProc.running = true
  }

  // Every action goes through run.sh as separate argv words; no shell parses
  // them, and run.sh re-checks each one before running aur-audit.
  function run(args) {
    Util.execArgv([runScript].concat(args))
    close()
  }

  function checkPackage(mode) {
    var name = packageField.text.trim()
    if (name === "") { packageError = "Type a package name first"; return }
    if (!packagePattern.test(name)) { packageError = "Not a valid package name"; return }
    packageError = ""
    run([mode, name])
    packageField.text = ""
  }

  onOpenedChanged: {
    if (opened) {
      // Looking at the panel counts as having seen any blocked installs.
      if (!markSeenProc.running) markSeenProc.running = true
      refresh()
    } else {
      packageError = ""
    }
  }

  Process {
    id: statusProc
    command: ["python3", root.statusScript]
    stdout: StdioCollector {
      onStreamFinished: {
        try { root.status = JSON.parse(text) } catch (e) { }
      }
    }
  }

  Process {
    id: markSeenProc
    command: ["python3", root.statusScript, "--mark-seen"]
    onExited: root.refresh()
  }

  // Cheap: lists the home folder and reads at most a few small reports.
  Timer {
    interval: root.opened ? 5000 : 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ---------- Bar icon ----------
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    active: root.level === "alert"
    dimmed: root.level === "stale" || root.level === "missing"
    tooltipText: root.opened ? "" : root.tooltip
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.run(["system"])
      else root.toggle()
    }
  }

  // ---------- Panel ----------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: packageField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "s") root.run(["system"])
        else if (t === "/" || t === "c") packageField.forceActiveFocus()
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.icon
            color: root.level === "alert" ? root.bar.urgent : root.bar.foreground
            opacity: root.level === "stale" || root.level === "missing" ? 0.6 : 1
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: root.headline
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              visible: text !== ""
              textFormat: Text.PlainText
              text: root.subline.toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        // ---------- Not installed ----------
        Column {
          visible: root.loaded && !root.installed
          width: parent.width
          spacing: Style.space(10)

          InfoText {
            width: parent.width
            wrapMode: Text.Wrap
            text: "This panel is a front-end for aur-audit, which isn't on your PATH. Install it first, then reopen this panel."
          }

          Button {
            text: "Open aur-audit on GitHub"
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            onClicked: { Qt.openUrlExternally(root.githubUrl); root.close() }
          }
        }

        // ---------- Protection ----------
        Column {
          visible: root.installed
          width: parent.width
          spacing: Style.spacing.labelGap

          InfoPair {
            label: "Pacman install check"
            value: root.status && root.status.hookInstalled ? "On" : "Off"
          }
          InfoPair {
            label: "yay pre-build check"
            value: root.status && root.status.yayWrapper ? "On" : "Off"
          }
        }

        PanelSeparator { visible: root.installed; foreground: root.bar.foreground }

        // ---------- System scan ----------
        Column {
          visible: root.installed
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "SCAN THIS SYSTEM"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: scanRow
            width: parent.width
            spacing: Style.space(6)

            Button {
              width: (scanRow.width - scanRow.spacing) / 2
              iconText: String.fromCodePoint(0xF0D9A)
              text: "Scan"
              tooltipText: "Free, rule-based scan. Takes about a minute."
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              onClicked: root.run(["system"])
            }

            Button {
              width: (scanRow.width - scanRow.spacing) / 2
              iconText: String.fromCodePoint(0xF06A9)
              text: "Scan + AI review"
              tooltipText: "Scans, then shows the token cost and asks before sending anything."
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              onClicked: root.run(["ai-system"])
            }
          }
        }

        // ---------- Check a package ----------
        Column {
          visible: root.installed
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "CHECK A PACKAGE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          TextField {
            id: packageField
            width: parent.width
            placeholderText: "AUR or installed package name"
            foreground: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            onTextEdited: root.packageError = ""
            onAccepted: root.checkPackage("check")
            Keys.onEscapePressed: { text = ""; keyCatcher.forceActiveFocus() }
          }

          InfoText {
            visible: root.packageError !== ""
            text: root.packageError
            color: root.bar.urgent
            opacity: 1
          }

          Row {
            id: packageRow
            width: parent.width
            spacing: Style.space(6)

            Button {
              width: (packageRow.width - packageRow.spacing) / 2
              iconText: String.fromCodePoint(0xF03D6)
              text: "Check before install"
              tooltipText: "Audit an AUR package by name without building or installing it."
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              onClicked: root.checkPackage("check")
            }

            Button {
              width: (packageRow.width - packageRow.spacing) / 2
              iconText: String.fromCodePoint(0xF06A9)
              text: "AI review installed"
              tooltipText: "Ask your AI assistant to review a package you already have. Shows the cost and asks first."
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              onClicked: root.checkPackage("ai-installed")
            }
          }
        }

        // ---------- Reports ----------
        Column {
          visible: root.installed
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            text: root.status && root.status.reportCount > root.reports.length
              ? "RECENT REPORTS (" + root.reports.length + " OF " + root.status.reportCount + ")"
              : "RECENT REPORTS"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          InfoText {
            visible: root.reports.length === 0
            text: "No reports yet. They're saved in your home folder."
          }

          Repeater {
            model: root.reports

            Item {
              id: reportRow
              required property var modelData
              readonly property var blockedTarget: {
                var pkgs = modelData.packages || []
                for (var i = 0; i < pkgs.length; i++)
                  if (pkgs[i].aiTarget) return pkgs[i].aiTarget
                return ""
              }

              width: parent.width
              implicitHeight: Math.max(rowLabels.implicitHeight + Style.space(8), aiButton.visible ? aiButton.height : 0)

              Rectangle {
                id: rowHover
                anchors.left: parent.left
                anchors.right: aiButton.visible ? aiButton.left : parent.right
                anchors.rightMargin: aiButton.visible ? Style.space(6) : 0
                height: parent.height
                radius: Style.cornerRadius
                color: Style.controlFill(false, rowMouse.containsMouse, root.bar.foreground, root.bar.foreground)

                MouseArea {
                  id: rowMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.run(["view", reportRow.modelData.path])
                }

                Text {
                  id: rowIcon
                  textFormat: Text.PlainText
                  text: root.reportIcon(reportRow.modelData.kind)
                  color: rowTitle.color
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                }

                Column {
                  id: rowLabels
                  anchors.left: rowIcon.right
                  anchors.leftMargin: Style.space(10)
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter

                  Text {
                    id: rowTitle
                    width: parent.width
                    textFormat: Text.PlainText
                    text: reportRow.modelData.title
                    color: root.reportIsAlarming(reportRow.modelData) ? root.bar.urgent : root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }

                  InfoText {
                    width: parent.width
                    text: reportRow.modelData.detail + "  ·  " + root.ago(reportRow.modelData.time)
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }
              }

              PanelActionButton {
                id: aiButton
                visible: reportRow.blockedTarget !== ""
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: String.fromCodePoint(0xF06A9)
                tooltipText: "Ask your AI assistant whether this blocked package is actually malicious"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                bordered: true
                onClicked: root.run(["ai", reportRow.blockedTarget])
              }
            }
          }
        }

        InfoText {
          visible: root.installed
          width: parent.width
          wrapMode: Text.Wrap
          text: "Middle-click the bar icon to scan · s scan · / check a package"
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoText { text: label }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    Text {
      textFormat: Text.PlainText
      text: value
      color: value === "Off" ? root.bar.urgent : root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  component InfoText: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
