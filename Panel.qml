import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// A compact SSH client in the bar. One icon, one popup: your imported
// sessions grouped exactly as they were in SecureCRT/PuTTY, a reachability
// dot per host, type-to-filter, Enter to connect in the default terminal.
Panel {
  id: root
  moduleName: "hussh"
  ipcTarget: "hussh"

  // ---- theme tokens (all sourced from the active Omarchy theme) ----------
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color muted: Qt.darker(foreground, 1.45)
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  // Reachability needs semantic colors, not theme colors. Many Omarchy
  // themes set `accent` to a red/coral (this one is #E75A50), which would
  // make "up" and "down" render identically. We derive a green and a red
  // that are guaranteed distinguishable, then tint each toward the theme
  // foreground so they still sit inside the palette rather than screaming.
  readonly property color okColor: Qt.tint(foreground, Qt.rgba(0.36, 0.72, 0.36, 0.82))
  readonly property color badColor: Qt.tint(foreground, Qt.rgba(0.85, 0.28, 0.28, 0.82))
  // Partially-up groups get amber: distinct from both green and red, and
  // distinct from the dim grey used for "no data yet" while a probe runs.
  readonly property color warnColor: Qt.tint(foreground, Qt.rgba(0.85, 0.62, 0.20, 0.82))
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal

  // The bar/popup icon is drawn (ShushIcon.qml), not a font glyph.
  readonly property string lockGlyph: "\uf023"    // nf-fa-lock
  readonly property string unlockGlyph: "\uf09c"  // nf-fa-unlock

  // ---- local UI state ----------------------------------------------------
  property string filterText: ""
  property int selectedIndex: -1
  property var rows: []              // flattened: {type:"group"|"session", ...}
  property var groupNames: []        // every group present after the last rebuild
  property bool askingPassword: false
  property bool showSettings: false

  Service {
    id: svc
    settings: root.settings
  }

  // ---- row flattening ----------------------------------------------------
  // Build a display list of group headers followed by their sessions, so the
  // imported hierarchy reads the way it did in SecureCRT.
  function rebuild(resetToTop) {
    var term = filterText.toLowerCase().trim()
    var searching = term.length > 0
    var matched = []
    for (var i = 0; i < svc.sessions.length; i++) {
      var s = svc.sessions[i]
      if (svc.hideUnreachable && svc.reachOf(s) === false) continue
      if (searching) {
        var hay = (s.name + " " + s.host + " " + s.group + " " +
                   s.description + " " + s.user).toLowerCase()
        if (hay.indexOf(term) === -1) continue
      }
      matched.push(s)
    }

    // Group, preserving first-seen order.
    var order = []
    var byGroup = ({})
    for (var j = 0; j < matched.length; j++) {
      var g = matched[j].group || ""
      if (byGroup[g] === undefined) { byGroup[g] = []; order.push(g) }
      byGroup[g].push(matched[j])
    }
    order.sort()
    groupNames = order.slice()

    var out = []
    for (var k = 0; k < order.length; k++) {
      var gname = order[k]
      var list = byGroup[gname]
      list.sort(function(a, b) { return a.name.localeCompare(b.name) })

      // Per-group reachability tally, so a collapsed header still tells you
      // what is inside it.
      var gUp = 0, gKnown = 0
      for (var t = 0; t < list.length; t++) {
        var rr = svc.reachOf(list[t])
        if (rr !== undefined) { gKnown++; if (rr) gUp++ }
      }

      // While filtering, force every group open — hiding matches behind a
      // collapsed header is the one thing a search must never do.
      var isCollapsed = !searching && svc.isCollapsed(gname)
      var hasHeader = (gname !== "" || order.length > 1)

      if (hasHeader) {
        out.push({ type: "group", group: gname,
                   label: gname === "" ? "Ungrouped" : gname,
                   count: list.length, up: gUp, known: gKnown,
                   collapsed: isCollapsed })
      }
      if (isCollapsed && hasHeader) continue
      for (var m = 0; m < list.length; m++) {
        out.push({ type: "session", session: list[m], group: gname })
      }
    }
    rows = out

    if (resetToTop || selectedIndex < 0 || selectedIndex >= rows.length) {
      selectedIndex = firstSelectableIndex()
    }
    scrollToSelected()
  }

  // Both group headers and sessions are selectable: headers so you can
  // collapse/expand them from the keyboard, sessions so you can connect.
  function firstSelectableIndex() {
    for (var i = 0; i < rows.length; i++)
      if (rows[i].type === "session" || rows[i].type === "group") return i
    return -1
  }

  function step(dir) {
    if (rows.length === 0) return
    var i = selectedIndex
    if (i < 0) i = dir > 0 ? -1 : rows.length
    for (var guard = 0; guard < rows.length; guard++) {
      i += dir
      if (i < 0) i = rows.length - 1
      if (i >= rows.length) i = 0
      if (rows[i].type === "session" || rows[i].type === "group") {
        selectedIndex = i; scrollToSelected(); return
      }
    }
  }

  function selectedRow() {
    if (selectedIndex < 0 || selectedIndex >= rows.length) return null
    return rows[selectedIndex]
  }

  function selectedSession() {
    var r = selectedRow()
    return r && r.type === "session" ? r.session : null
  }

  // Enter: connect on a session, expand/collapse on a group header.
  function activateSelected() {
    var r = selectedRow()
    if (!r) return
    if (r.type === "group") { svc.toggleGroup(r.group); rebuild(false); return }
    close()
    svc.connect(r.session)
  }

  // Left/Right collapse and expand, like a normal tree view. On a session
  // row, Left jumps up to its own group header and collapses it.
  function collapseCurrent() {
    var r = selectedRow()
    if (!r) return
    if (r.type === "group") {
      if (!svc.isCollapsed(r.group)) { svc.toggleGroup(r.group); rebuild(false) }
      return
    }
    // Session: walk back to its header, select it, collapse it.
    for (var i = selectedIndex; i >= 0; i--) {
      if (rows[i].type === "group" && rows[i].group === r.group) {
        selectedIndex = i
        if (!svc.isCollapsed(rows[i].group)) { svc.toggleGroup(rows[i].group); rebuild(false) }
        return
      }
    }
  }

  function expandCurrent() {
    var r = selectedRow()
    if (!r || r.type !== "group") return
    if (svc.isCollapsed(r.group)) { svc.toggleGroup(r.group); rebuild(false) }
    else step(1)   // already open: drop into the first child
  }

  function collapseAll() {
    svc.setAllCollapsed(groupNames, true)
    rebuild(true)
  }

  function expandAll() {
    svc.setAllCollapsed(groupNames, false)
    rebuild(true)
  }

  function allCollapsed() {
    if (groupNames.length === 0) return false
    for (var i = 0; i < groupNames.length; i++)
      if (!svc.isCollapsed(groupNames[i])) return false
    return true
  }

  function scrollToSelected() {
    if (selectedIndex < 0) return
    Qt.callLater(function() {
      var item = rowRepeater.itemAt(selectedIndex)
      if (!item || listFlick.contentHeight <= listFlick.height) return
      var top = item.y
      var bottom = item.y + item.height
      if (top < listFlick.contentY) listFlick.contentY = top
      else if (bottom > listFlick.contentY + listFlick.height)
        listFlick.contentY = bottom - listFlick.height
    })
  }

  function statusColor(s) {
    var r = svc.reachOf(s)
    if (r === true) return root.okColor
    if (r === false) return root.badColor
    return root.dim   // never probed
  }

  function statusTip(s) {
    var r = svc.reachOf(s)
    if (r === true) return "reachable"
    if (r === false) return "no answer on port " + s.port
    return "not probed yet"
  }

  Connections {
    target: svc
    function onSessionsChanged() { root.rebuild(true) }
    function onReachChanged() { root.rebuild(false) }
    function onCollapsedChanged() { root.rebuild(false) }
    function onUiStateLoadedChanged() { root.rebuild(true) }
  }

  // ---- bar button --------------------------------------------------------
  readonly property string barTooltip: {
    if (!svc.loaded) return "huSSH — loading…"
    if (svc.sessions.length === 0) return "huSSH — no sessions imported"
    var up = 0, known = 0
    for (var i = 0; i < svc.sessions.length; i++) {
      var r = svc.reachOf(svc.sessions[i])
      if (r !== undefined) { known++; if (r) up++ }
    }
    var base = svc.sessions.length + " session" + (svc.sessions.length === 1 ? "" : "s")
    if (known > 0) base += " · " + up + " up"
    base += svc.unlocked ? " · unlocked " + svc.credTtl : " · locked"
    return base
  }

  implicitWidth: button.item ? button.item.implicitWidth : 0
  implicitHeight: button.item ? button.item.implicitHeight : barSize

  onOpenedChanged: {
    if (opened) {
      svc.everOpened = true
      svc.refreshCred()
      svc.probe()
      filterText = ""
      askingPassword = false
      rebuild(true)
      keyCatcher.forceActiveFocus()
    }
  }

  Loader {
    id: button
    anchors.fill: parent
    sourceComponent: BarIconButton {
      id: barBtn
      bar: root.bar
      // Drawn rather than a font glyph: Nerd Font has no shushing face, and
      // the 🤫 emoji renders in fixed colour so it cannot follow the theme.
      // iconComponent is BarIconButton's own slot for custom content.
      iconComponent: Component {
        ShushIcon {
          anchors.fill: parent
          strokeColor: barBtn.active && barBtn.useActiveColor
                       ? barBtn.activeColor : barBtn.foreground
          backgroundColor: Color.background
        }
      }
      tooltipText: root.barTooltip
      active: svc.probing
      onPressed: function(code) {
        if (code === Qt.RightButton) svc.probe()
        else root.toggle()
      }
    }
  }

  // ---- popup -------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus || passwordField.activeFocus

      onCloseRequested: root.close()
      Keys.onUpPressed: root.step(-1)
      Keys.onDownPressed: root.step(1)
      Keys.onLeftPressed: root.collapseCurrent()
      Keys.onRightPressed: root.expandCurrent()
      Keys.onReturnPressed: root.activateSelected()
      Keys.onEnterPressed: root.activateSelected()
      Keys.onEscapePressed: root.close()
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Slash) {
          searchField.forceActiveFocus(); event.accepted = true; return
        }
        if (event.key === Qt.Key_Space) {
          var r = root.selectedRow()
          if (r && r.type === "group") {
            svc.toggleGroup(r.group); root.rebuild(false); event.accepted = true; return
          }
        }
        var k = event.text
        if (k === "u") {
          if (svc.unlocked) svc.lock()
          else { root.askingPassword = true; passwordFocusTimer.restart() }
          event.accepted = true
        } else if (k === "r") { svc.probe(); event.accepted = true }
        else if (k === ",") { root.showSettings = !root.showSettings; event.accepted = true }
        else if (k === "c") { root.collapseAll(); event.accepted = true }
        else if (k === "e") { root.expandAll(); event.accepted = true }
      }

      Timer {
        id: passwordFocusTimer
        interval: 60
        onTriggered: if (root.askingPassword) passwordField.forceActiveFocus()
      }

      ColumnLayout {
        id: column
        anchors.fill: parent
        spacing: Style.space(10)

        PanelHero {
          Layout.fillWidth: true
          title: "huSSH"
          meta: {
            if (!svc.loaded) return "Loading…"
            if (svc.sessions.length === 0) return "No sessions"
            var shown = 0
            for (var i = 0; i < root.rows.length; i++)
              if (root.rows[i].type === "session") shown++
            var up = 0, known = 0
            for (var j = 0; j < svc.sessions.length; j++) {
              var r = svc.reachOf(svc.sessions[j])
              if (r !== undefined) { known++; if (r) up++ }
            }
            var s = shown + " of " + svc.sessions.length
            if (known > 0) s += " · " + up + " up / " + (known - up) + " down"
            if (svc.probing) s += " · probing…"
            return s
          }
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconComponent: Component {
            ShushIcon {
              implicitWidth: Style.font.display
              implicitHeight: Style.font.display
              strokeColor: root.foreground
              backgroundColor: Color.background
            }
          }
          trailingControl: Component {
            RowLayout {
              spacing: Style.space(6)
              PanelActionButton {
                iconText: root.allCollapsed() ? "\uf0fe" : "\uf146"  // plus-square / minus-square
                tooltipText: root.allCollapsed() ? "Expand all groups" : "Collapse all groups"
                foreground: root.foreground
                fontFamily: root.fontFamily
                visible: root.groupNames.length > 1
                onClicked: root.allCollapsed() ? root.expandAll() : root.collapseAll()
              }
              PanelActionButton {
                iconText: svc.unlocked ? root.unlockGlyph : root.lockGlyph
                tooltipText: svc.unlocked
                  ? "Credential cached (" + svc.credTtl + ") — click to lock now"
                  : "Unlock: cache your TACACS password in RAM"
                foreground: svc.unlocked ? root.okColor : root.foreground
                fontFamily: root.fontFamily
                onClicked: {
                  if (svc.unlocked) svc.lock()
                  else { root.askingPassword = true; passwordFocusTimer.restart() }
                }
              }
              PanelActionButton {
                iconText: "\uf013"
                tooltipText: root.showSettings ? "Hide settings" : "Settings"
                foreground: root.showSettings ? root.okColor : root.foreground
                fontFamily: root.fontFamily
                onClicked: root.showSettings = !root.showSettings
              }
              PanelActionButton {
                iconText: "\uf021"
                tooltipText: "Re-probe all hosts"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !svc.probing
                onClicked: svc.probe()
              }
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: svc.lastError !== ""
          Layout.fillWidth: true
          text: svc.lastError
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        // Password prompt. Only appears when you ask for it; the value goes
        // straight to the service over stdin and is cleared immediately.
        RowLayout {
          Layout.fillWidth: true
          visible: root.askingPassword
          spacing: Style.space(6)

          TextField {
            id: passwordField
            Layout.fillWidth: true
            echoMode: TextInput.Password
            placeholderText: "TACACS password — held in RAM for " + svc.unlockMinutes + "m"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            onAccepted: {
              svc.unlock(text)
              text = ""
              root.askingPassword = false
              keyCatcher.forceActiveFocus()
            }
            Keys.onEscapePressed: {
              text = ""
              root.askingPassword = false
              keyCatcher.forceActiveFocus()
            }
          }
        }

        // Settings. Collapsed by default; the gear in the hero toggles it.
        // Username and unlock window persist to settings.json; the password
        // does NOT — it goes to the kernel keyring and expires on its own.
        Rectangle {
          Layout.fillWidth: true
          visible: root.showSettings
          implicitHeight: settingsCol.implicitHeight + Style.space(16)
          radius: Style.cornerRadius
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
          border.width: 1
          border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

          ColumnLayout {
            id: settingsCol
            anchors.fill: parent
            anchors.margins: Style.space(8)
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              text: "Settings"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            // --- default username -------------------------------------
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: "Username"
                color: root.foreground
                opacity: 0.75
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                Layout.preferredWidth: Style.space(70)
              }

              TextField {
                id: userField
                Layout.fillWidth: true
                placeholderText: "used where a session has none"
                text: svc.defaultUser
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                onEditingFinished: svc.setDefaultUser(text)
                Keys.onEscapePressed: { text = svc.defaultUser; keyCatcher.forceActiveFocus() }
              }
            }

            // --- password (RAM only) ----------------------------------
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: "Password"
                color: root.foreground
                opacity: 0.75
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                Layout.preferredWidth: Style.space(70)
              }

              TextField {
                id: settingsPwField
                Layout.fillWidth: true
                echoMode: TextInput.Password
                enabled: !svc.unlocked
                placeholderText: svc.unlocked
                  ? "cached — " + svc.credTtl + " remaining"
                  : "cached in RAM for " + svc.unlockMinutes + "m, never written to disk"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                onAccepted: { svc.unlock(text); text = "" }
                Keys.onEscapePressed: { text = ""; keyCatcher.forceActiveFocus() }
              }

              Button {
                text: svc.unlocked ? "Lock" : "Cache"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: {
                  if (svc.unlocked) { svc.lock() }
                  else { svc.unlock(settingsPwField.text); settingsPwField.text = "" }
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: "Password lives only in the kernel keyring and expires automatically. "
                  + "It is never saved to a file."
              color: root.foreground
              opacity: 0.55
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Rectangle {
              Layout.fillWidth: true
              implicitHeight: 1
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
            }

            // --- session import ---------------------------------------
            Text {
              textFormat: Text.PlainText
              text: "Import sessions"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              TextField {
                id: importField
                Layout.fillWidth: true
                placeholderText: "path to .json / .xml (or a SecureCRT / PuTTY export)"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                onAccepted: svc.importSessions(text, mergeToggle.merge)
                Keys.onEscapePressed: keyCatcher.forceActiveFocus()
              }

              Button {
                id: mergeToggle
                property bool merge: false
                text: merge ? "Merge" : "Replace"
                bordered: true
                tooltipText: merge
                  ? "Add to existing sessions"
                  : "Replace all existing sessions"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: merge = !merge
              }

              Button {
                text: svc.importing ? "…" : "Import"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !svc.importing && importField.text !== ""
                onClicked: svc.importSessions(importField.text, mergeToggle.merge)
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: svc.importStatus !== ""
              Layout.fillWidth: true
              text: svc.importStatus
              color: svc.importStatus.indexOf("Failed") === 0 ? root.badColor : root.foreground
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }
        }

        TextField {
          id: searchField
          Layout.fillWidth: true
          placeholderText: "Filter by name, host, group…"
          text: root.filterText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          leftPadding: Style.space(8)
          rightPadding: Style.space(8)
          onTextChanged: {
            root.filterText = text
            root.rebuild(true)
          }
          Keys.onUpPressed: root.step(-1)
          Keys.onDownPressed: root.step(1)
          Keys.onReturnPressed: root.activateSelected()
          Keys.onEnterPressed: root.activateSelected()
          Keys.onEscapePressed: {
            if (text.length > 0) { text = "" }
            else { keyCatcher.forceActiveFocus() }
          }
        }

        Flickable {
          id: listFlick
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.preferredHeight: Math.min(listColumn.implicitHeight, Style.space(430))
          contentWidth: width
          contentHeight: listColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: listColumn
            width: listFlick.width
            spacing: Style.space(2)

            Repeater {
              id: rowRepeater
              model: root.rows

              delegate: Item {
                id: row
                required property var modelData
                required property int index
                width: parent.width
                implicitHeight: modelData.type === "group"
                  ? groupLoader.implicitHeight
                  : sessionLoader.implicitHeight

                property bool isSelected: root.selectedIndex === index

                Rectangle {
                  anchors.fill: parent
                  color: root.selectedBackground
                  visible: row.isSelected
                  radius: Style.space(4)
                  z: -1
                }

                // --- group header ---
                Loader {
                  id: groupLoader
                  width: parent.width
                  active: row.modelData.type === "group"
                  visible: active
                  sourceComponent: Item {
                    implicitHeight: ghRow.implicitHeight + Style.space(10)

                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        root.selectedIndex = row.index
                        svc.toggleGroup(row.modelData.group)
                        root.rebuild(false)
                      }
                    }

                    RowLayout {
                      id: ghRow
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.bottom: parent.bottom
                      anchors.bottomMargin: Style.space(3)
                      anchors.leftMargin: Style.space(4)
                      anchors.rightMargin: Style.space(4)
                      spacing: Style.space(6)

                      // Disclosure chevron: ▸ collapsed, ▾ expanded.
                      Text {
                        textFormat: Text.PlainText
                        text: row.modelData.collapsed ? "\u25B8" : "\u25BE"
                        color: row.isSelected ? root.selectedText : root.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }

                      Text {
                        textFormat: Text.PlainText
                        Layout.fillWidth: true
                        text: row.modelData.label
                        color: row.isSelected ? root.selectedText : root.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        elide: Text.ElideRight
                      }

                      // Per-group tally. A collapsed header still reports what
                      // is inside, so you can skip opening a healthy group.
                      //
                      // Both the text and the colour compare `up` against
                      // `count` (every session in the group), never against
                      // `known` (how many have been probed so far). Mixing the
                      // two made a fully-up group render as if it were partial
                      // whenever a probe was still in flight.
                      Text {
                        textFormat: Text.PlainText
                        text: {
                          var m = row.modelData
                          if (m.known <= 0) return "(" + m.count + ")"
                          // Mid-sweep: say so, rather than implying the
                          // missing hosts are down.
                          if (m.known < m.count) return m.up + "/" + m.count + " up…"
                          return m.up + "/" + m.count + " up"
                        }
                        color: {
                          var m = row.modelData
                          if (m.known <= 0) return root.dim        // no data yet
                          if (m.known < m.count) return root.dim   // still probing
                          if (m.up === 0) return root.badColor     // all down
                          if (m.up < m.count) return root.warnColor // partially up
                          return root.okColor                      // all up
                        }
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }
                }

                // --- session row ---
                Loader {
                  id: sessionLoader
                  width: parent.width
                  active: row.modelData.type === "session"
                  visible: active
                  sourceComponent: Item {
                    implicitHeight: srow.implicitHeight + Style.space(6) * 2

                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        root.selectedIndex = row.index
                        root.close()
                        svc.connect(row.modelData.session)
                      }
                    }

                    RowLayout {
                      id: srow
                      anchors.fill: parent
                      anchors.margins: Style.space(6)
                      anchors.leftMargin: Style.space(10)
                      spacing: Style.space(8)

                      // Reachability indicator. Color AND shape both encode
                      // state: a filled dot is up, a hollow ring is down, a
                      // faint hollow ring means "not probed yet". Shape means
                      // the status survives any theme's color choices.
                      Item {
                        Layout.alignment: Qt.AlignVCenter
                        implicitWidth: Style.space(9)
                        implicitHeight: Style.space(9)

                        property var reachState: svc.reachOf(row.modelData.session)

                        Rectangle {
                          anchors.centerIn: parent
                          width: Style.space(9)
                          height: Style.space(9)
                          radius: width / 2
                          color: parent.reachState === true
                            ? root.okColor : "transparent"
                          border.width: parent.reachState === true ? 0 : Math.max(1, Style.space(2))
                          border.color: parent.reachState === false
                            ? root.badColor : root.dim
                          opacity: parent.reachState === undefined ? 0.5 : 1.0
                        }

                        MouseArea {
                          id: dotHover
                          anchors.fill: parent
                          anchors.margins: -Style.space(4)
                          hoverEnabled: true
                          acceptedButtons: Qt.NoButton
                        }

                        PanelToolTip {
                          visible: dotHover.containsMouse
                          text: root.statusTip(row.modelData.session)
                          fontFamily: root.fontFamily
                        }
                      }

                      Column {
                        Layout.fillWidth: true
                        spacing: Style.space(2)

                        Text {
                          textFormat: Text.PlainText
                          width: parent.width
                          text: row.modelData.session.name
                          color: row.isSelected ? root.selectedText : root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                          font.bold: true
                          elide: Text.ElideRight
                        }

                        Text {
                          textFormat: Text.PlainText
                          width: parent.width
                          text: {
                            var s = row.modelData.session
                            var t = (s.user ? s.user + "@" : "") + s.host
                            if (s.port !== 22) t += ":" + s.port
                            if (s.protocol === "telnet") t += "  (telnet)"
                            if (s.description) t += "  · " + s.description
                            return t
                          }
                          color: root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          elide: Text.ElideRight
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: svc.loaded && svc.sessions.length === 0
          Layout.fillWidth: true
          text: "No sessions yet.\nOpen settings (the gear, or press ,) to import a .json / .xml\nsession file, or a SecureCRT / PuTTY export."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }

        Text {
          textFormat: Text.PlainText
          visible: svc.sessions.length > 0
          Layout.fillWidth: true
          text: "/: filter   ↑↓: move   ←→: fold   ⏎: connect   c/e: all   u: " +
                (svc.unlocked ? "lock" : "unlock") + "   r: probe   ,: settings"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
