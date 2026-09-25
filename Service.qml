import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Owns everything off-GUI: loading sessions.json, sweeping reachability,
// tracking the credential lock state, and launching connections.
// The Panel only renders what this exposes.
Item {
  id: root

  property var settings: ({})

  // ---- exposed state -----------------------------------------------------
  property var sessions: []          // flat list of session objects
  property var reach: ({})           // "host:port" -> bool
  property bool loaded: false
  property bool probing: false
  property string lastError: ""

  // Credential state: "locked" | "unlocked"
  property string credState: "locked"
  property string credTtl: ""
  readonly property bool unlocked: credState === "unlocked"

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")
  readonly property string binDir: pluginDir + "bin/"

  function setting(name, fallback) {
    var v = settings ? settings[name] : undefined
    return v === undefined || v === null ? fallback : v
  }

  readonly property bool probeEnabled: String(setting("probeEnabled", true)) !== "false"
  readonly property int probeSeconds: Math.max(15, Math.min(900, parseInt(setting("probeSeconds", 60), 10) || 60))
  readonly property real probeTimeout: Math.max(0.3, Math.min(10, parseFloat(setting("probeTimeout", 1.5)) || 1.5))
  // Effective unlock window: the settings-file value wins when present,
  // otherwise the bar widget's manifest setting, clamped to sane bounds.
  readonly property int unlockMinutes: Math.max(5, Math.min(480,
      root.unlockMinutesOverride > 0
        ? root.unlockMinutesOverride
        : (parseInt(setting("unlockMinutes", 60), 10) || 60)))
  readonly property bool hideUnreachable: String(setting("hideUnreachable", false)) === "true"

  // Strip control characters from anything that came out of an imported file.
  function sanitize(s, maxLen) {
    if (!s) return ""
    var t = String(s).replace(/[\x00-\x1F\x7F]/g, "")
    return t.length > maxLen ? t.slice(0, maxLen) : t
  }

  function keyOf(s) { return s.host + ":" + s.port }

  // true / false / undefined (never probed)
  function reachOf(s) { return reach[keyOf(s)] }

  // ---- collapsed-group state (persisted) ---------------------------------
  // Map of groupName -> true for every collapsed group. Persisted next to
  // sessions.json so the popup opens the way you left it.
  property var collapsed: ({})
  property bool uiStateLoaded: false

  FileView {
    id: uiStateFile
    path: Quickshell.env("HOME") + "/.config/omarchy/hussh/ui-state.json"
    watchChanges: false
    printErrors: false
    onLoaded: {
      try {
        var doc = JSON.parse(text() || "{}")
        var c = ({})
        var list = doc.collapsed || []
        for (var i = 0; i < list.length; i++) c[String(list[i])] = true
        root.collapsed = c
      } catch (e) { root.collapsed = ({}) }
      root.uiStateLoaded = true
    }
    onLoadFailed: { root.collapsed = ({}); root.uiStateLoaded = true }
  }

  // ---------------------------------------------------------------- settings
  //
  // Only non-secret preferences live here. The TACACS password is deliberately
  // absent: it goes straight into the kernel keyring via hussh-cred and is
  // never written to disk, so a settings file leak costs nothing.
  property string defaultUser: ""
  property int unlockMinutesOverride: 0
  property bool settingsLoaded: false

  FileView {
    id: settingsFile
    path: Quickshell.env("HOME") + "/.config/omarchy/hussh/settings.json"
    watchChanges: false
    printErrors: false
    onLoaded: {
      try {
        var doc = JSON.parse(text() || "{}")
        root.defaultUser = String(doc.defaultUser || "")
        var m = parseInt(doc.unlockMinutes)
        if (!isNaN(m) && m > 0) root.unlockMinutesOverride = m
      } catch (e) { /* keep defaults */ }
      root.settingsLoaded = true
    }
    onLoadFailed: { root.settingsLoaded = true }
  }

  function persistSettings() {
    if (!root.settingsLoaded) return
    settingsFile.setText(JSON.stringify({
      defaultUser: root.defaultUser,
      unlockMinutes: root.unlockMinutesOverride
    }, null, 2))
  }

  function setDefaultUser(u) {
    root.defaultUser = String(u || "").trim()
    root.persistSettings()
  }

  function setUnlockMinutes(m) {
    var v = parseInt(m)
    if (isNaN(v) || v < 1) return
    root.unlockMinutesOverride = v
    root.persistSettings()
  }

  // ----------------------------------------------------------------- import
  property bool importing: false
  property string importStatus: ""

  Process {
    id: importProc
    running: false
    stdout: StdioCollector { id: importOut }
    stderr: StdioCollector { id: importErr }
    onExited: function (code) {
      root.importing = false
      if (code === 0) {
        var line = String(importOut.text || "").trim().split("\n").pop()
        root.importStatus = line || "Import complete"
        sessionsFile.reload()          // pick up the new sessions.json
      } else {
        var msg = String(importErr.text || "").trim().split("\n").pop()
        root.importStatus = msg ? ("Failed: " + msg) : "Import failed"
      }
    }
  }

  function importSessions(path, merge) {
    var p = String(path || "").trim()
    if (!p || importProc.running) return
    if (p.indexOf("~") === 0) p = Quickshell.env("HOME") + p.substring(1)
    var cmd = [root.binDir + "hussh-import", p]
    if (merge) cmd.push("--merge")
    if (root.defaultUser) { cmd.push("--default-user"); cmd.push(root.defaultUser) }
    root.importStatus = "Importing…"
    root.importing = true
    importProc.command = cmd
    importProc.running = true
  }

  function persistCollapsed() {
    var list = []
    for (var k in collapsed) if (collapsed[k]) list.push(k)
    list.sort()
    uiStateFile.setText(JSON.stringify({ version: 1, collapsed: list }, null, 2) + "\n")
  }

  function isCollapsed(group) { return collapsed[group] === true }

  function toggleGroup(group) {
    var next = ({})
    for (var k in collapsed) next[k] = collapsed[k]
    if (next[group]) delete next[group]
    else next[group] = true
    collapsed = next
    persistCollapsed()
  }

  function setAllCollapsed(groups, state) {
    var next = ({})
    if (state) for (var i = 0; i < groups.length; i++) next[groups[i]] = true
    collapsed = next
    persistCollapsed()
  }

  // ---- sessions.json -----------------------------------------------------
  FileView {
    id: sessionsFile
    path: Quickshell.env("HOME") + "/.config/omarchy/hussh/sessions.json"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.parseSessions(text())
    onLoadFailed: function(err) {
      root.sessions = []
      root.loaded = true
      root.lastError = "No sessions.json yet — run bin/hussh-import"
    }
  }

  function parseSessions(raw) {
    var out = []
    try {
      var doc = JSON.parse(raw || "{}")
      var list = doc.sessions || []
      for (var i = 0; i < list.length && i < 2000; i++) {
        var s = list[i]
        if (!s || !s.host) continue
        var port = parseInt(s.port, 10)
        if (!isFinite(port) || port <= 0 || port > 65535) port = 22
        out.push({
          name: sanitize(s.name || s.host, 96),
          host: sanitize(s.host, 255),
          port: port,
          user: sanitize(s.user || "", 64),
          protocol: (s.protocol === "telnet") ? "telnet" : "ssh",
          group: sanitize(s.group || "", 160),
          description: sanitize(s.description || "", 160),
          identity: sanitize(s.identity || "", 255)
        })
      }
      root.lastError = ""
    } catch (e) {
      root.lastError = "sessions.json is not valid JSON"
    }
    root.sessions = out
    root.loaded = true
  }

  // ---- reachability probe ------------------------------------------------
  Process {
    id: probeProc
    command: [root.binDir + "hussh-probe"]
    environment: ({
      "HUSSH_PROBE_TIMEOUT": String(root.probeTimeout)
    })
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var r = JSON.parse(text || "{}")
          if (r._error) { root.lastError = root.sanitize(r._error, 200) }
          else { root.reach = r }
        } catch (e) { /* keep previous results */ }
        root.probing = false
        probeTimeout.running = false
      }
    }
    onExited: { root.probing = false; probeTimeout.running = false }
  }

  Timer {
    id: probeTimeout
    interval: 30000
    repeat: false
    onTriggered: if (probeProc.running) probeProc.signal(9)
  }

  function probe() {
    if (!probeEnabled || probeProc.running || sessions.length === 0) return
    probing = true
    probeProc.running = true
    probeTimeout.running = true
  }

  // Only sweeps once the user has actually opened the popup, so an unused
  // widget costs nothing.
  property bool everOpened: false
  Timer {
    id: probeTimer
    interval: root.probeSeconds * 1000
    repeat: true
    running: root.everOpened && root.probeEnabled
    triggeredOnStart: true
    onTriggered: root.probe()
  }

  // ---- credential state --------------------------------------------------
  Process {
    id: credStatusProc
    command: [root.binDir + "hussh-cred", "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "").trim()
        if (t.indexOf("unlocked") === 0) {
          root.credState = "unlocked"
          var parts = t.split(/\s+/)
          root.credTtl = parts.length > 1 ? parts[1] : ""
        } else {
          root.credState = "locked"
          root.credTtl = ""
        }
      }
    }
  }

  function refreshCred() {
    if (!credStatusProc.running) credStatusProc.running = true
  }

  Timer {
    interval: 20000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refreshCred()
  }

  // Unlock: the password goes in on STDIN, never argv — so it cannot be
  // seen in /proc/<pid>/cmdline by anything on the box.
  Process {
    id: unlockProc
    stdinEnabled: true
    property string pending: ""
    onStarted: {
      if (pending.length > 0) {
        write(pending + "\n")
        pending = ""
      }
      stdinEnabled = false
    }
    stdout: StdioCollector { waitForEnd: true }
    onExited: { pending = ""; root.refreshCred() }
  }

  function unlock(password) {
    if (!password || unlockProc.running) return
    unlockProc.command = [root.binDir + "hussh-cred", "unlock", String(root.unlockMinutes)]
    unlockProc.stdinEnabled = true
    unlockProc.pending = password
    unlockProc.running = true
  }

  Process {
    id: lockProc
    command: [root.binDir + "hussh-cred", "lock"]
    stdout: StdioCollector { waitForEnd: true }
    onExited: root.refreshCred()
  }

  function lock() { if (!lockProc.running) lockProc.running = true }

  // ---- connect -----------------------------------------------------------
  function connect(s) {
    if (!s || !s.host) return
    // Sessions imported without a username fall back to the configured
    // default, so you set it once instead of editing every entry.
    var user = String(s.user || "").trim() || root.defaultUser
    Quickshell.execDetached([
      root.binDir + "hussh-connect",
      s.host, String(s.port), user, s.protocol, s.name, s.identity || ""
    ])
  }

  Component.onCompleted: refreshCred()
}
