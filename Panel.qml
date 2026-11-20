import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Ui
import qs.Commons
import qs.Commons as Commons

// Display presets: one click puts each app on the screen it belongs to.
// All the window work happens in ./presetctl (Python, stdlib only); this file
// only draws the presets and runs that script.
Panel {
  id: root
  moduleName: "gijux9x.presets"
  ipcTarget: "gijux9x.presets"
  // Own the IPC target so it can carry apply/capture/refresh as well.
  manageIpc: false

  Commons.Translations { id: tr; directory: Qt.resolvedUrl("i18n") }

  readonly property string ctl: decodeURIComponent(String(Qt.resolvedUrl("presetctl")).replace(/^file:\/\//, ""))
  readonly property bool closeOnApply: setting("closeOnApply", true) === true

  property var model: ({ monitors: [], presets: [], hidden: 0, error: "", exists: true, config: "" })
  readonly property var presets: model.presets || []
  readonly property var monitors: model.monitors || []

  property int selectedIndex: 0
  property bool cursorActive: false
  property string applyingId: ""
  property string doneId: ""
  property string lastAppliedId: ""
  property string armedDeleteId: ""
  property string message: ""
  property bool messageIsError: false
  property string editMode: ""        // "", "capture" or "rename"
  property string editTargetId: ""
  property string editSeed: ""
  property int editSeq: 0
  property bool refreshQueued: false
  property var actionAfter: null

  // ---- Editor: which apps go on which screen. Works on a draft that is only
  // written to presets.json when the user presses Save.
  property bool editing: false
  property string editorId: ""
  property bool editorDirty: false
  property bool editorLeaveArmed: false
  property string draftName: ""
  property string draftOthers: "keep"
  property string draftFocus: ""
  property var draftScreens: []      // [{ position, label, monitor, apps: [app] }]
  property var draftUnresolved: []
  property int draftLoadSeq: 0       // bumped when a draft is (re)loaded, so text fields refill
  property int draftRev: 0           // bumped by in-place text edits, so labels follow
  property int pickerScreen: -1      // screen whose app picker is open
  property bool pickerCustom: false
  property string pickerQuery: ""
  property string expandedKey: ""    // "screen:app" of the row whose details are open
  readonly property int appsRev: DesktopEntries.applications.values.length
  readonly property int maxCount: 12
  readonly property int maxTiles: 16
  property int tileScreen: -1        // screen whose tile is selected
  property string tilePath: ""       // path of the selected tile: "a"/"b" per split, from the root
  property bool pickerReplace: false // the picker changes the selected tile instead of adding one
  property bool pickerFree: false    // the picker chooses the first tile of an empty screen
  property var pickerBrowser: null   // browser being set up: asks for the address to open
  property string pickerUrl: ""
  property bool pickerWebapp: true   // open as a web app (no address bar) rather than a plain window
  // Asks the panel content to take the keyboard focus back (editor or list).
  signal refocus()

  readonly property color fg: root.bar ? root.bar.foreground : Commons.Color.foreground
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property color dimFg: Qt.rgba(fg.r, fg.g, fg.b, 0.55)
  readonly property color faintFg: Qt.rgba(fg.r, fg.g, fg.b, 0.3)
  readonly property color hoverFill: Style.hoverFillFor(fg, Commons.Color.accent)
  readonly property color selectedFill: Style.selectedFillFor(fg, Commons.Color.accent)

  // ------------------------------------------------------------------ data

  function refresh() {
    if (listProc.running) { refreshQueued = true; return }
    listProc.running = true
  }

  function takeList(text) {
    var parsed = null
    try { parsed = JSON.parse(String(text || "")) } catch (e) { parsed = null }
    if (!parsed || typeof parsed !== "object" || !Array.isArray(parsed.presets)) {
      if (String(text || "").trim() !== "") showMessage(tr.t("error.failed"), true)
      return
    }
    model = parsed
    if (selectedIndex >= presets.length) selectedIndex = Math.max(0, presets.length - 1)
    if (refreshQueued) { refreshQueued = false; Qt.callLater(refresh) }
  }

  function showMessage(text, isError) {
    message = String(text || "")
    messageIsError = !!isError
    messageTimer.restart()
  }

  function positionLabel(position) {
    if (position === "left" || position === "middle" || position === "right") return tr.t("pos." + position)
    if (/^\d+$/.test(String(position))) return tr.t("pos.n").arg(position)
    return String(position || "")
  }

  function iconFor(hint) {
    // Read so icons fill in once the desktop entries finish loading.
    var revision = DesktopEntries.applications.values.length
    var value = String(hint || "")
    if (value === "") return ""
    if (value.charAt(0) === "/") return "file://" + value
    var themed = Quickshell.iconPath(value, true)
    if (themed) return themed
    var entry = DesktopEntries.heuristicLookup(value)
    if (entry && entry.icon) return Quickshell.iconPath(entry.icon, true)
    return ""
  }

  // --------------------------------------------------------------- actions

  function applyPreset(id) {
    if (!id || applyProc.running) return
    cancelEdit()
    armedDeleteId = ""
    applyingId = id
    doneId = ""
    message = ""
    applyProc.command = ["python3", root.ctl, "apply", id, "--json"]
    applyProc.running = true
  }

  function applyIndex(i) {
    if (i >= 0 && i < presets.length) {
      selectedIndex = i
      applyPreset(presets[i].id)
    }
  }

  function takeApplyResult(text) {
    var id = applyingId
    applyingId = ""
    var result = null
    try { result = JSON.parse(String(text || "").trim().split("\n").pop()) } catch (e) { result = null }
    if (!result) {
      showMessage(applyErr.text.trim() || tr.t("error.failed"), true)
      refresh()
      return
    }
    if (result.error) {
      showMessage(result.error, true)
    } else if (result.warnings && result.warnings.length > 0) {
      showMessage(result.warnings.join(" · "), !result.ok)
    }
    if (result.ok) {
      lastAppliedId = id
      doneId = id
      doneTimer.restart()
      if (root.closeOnApply && !(result.warnings && result.warnings.length)) closeTimer.restart()
    }
    refresh()
  }

  property var actionQueue: []

  function run(args, after) {
    if (actionProc.running) {
      // A click made while another action runs is done right after it, not lost.
      actionQueue = actionQueue.concat([{ args: args, after: after || null }])
      return
    }
    actionAfter = after || null
    actionProc.command = ["python3", root.ctl].concat(args)
    actionProc.running = true
  }

  function runNext() {
    if (actionQueue.length === 0 || actionProc.running) return
    var next = actionQueue[0]
    actionQueue = actionQueue.slice(1)
    run(next.args, next.after)
  }

  function startCapture() {
    editMode = "capture"
    editTargetId = ""
    editSeed = tr.t("field.defaultName").arg(Qt.formatDateTime(new Date(), "dd/MM HH:mm"))
    editSeq++
  }

  function startRename(id) {
    var p = presets.filter(function(x) { return x.id === id })[0]
    if (!p) return
    editMode = "rename"
    editTargetId = id
    editSeed = p.name
    editSeq++
  }

  function cancelEdit() {
    editMode = ""
    editTargetId = ""
  }

  function commitEdit(text) {
    var name = String(text || "").trim()
    if (name === "") { cancelEdit(); return }
    if (editMode === "capture") {
      run(["capture", "--name", name], function(ok) { if (ok) showMessage(tr.t("msg.captured").arg(name), false) })
    } else if (editMode === "rename" && editTargetId !== "") {
      run(["rename", editTargetId, name])
    }
    cancelEdit()
  }

  function requestDelete(id) {
    if (!id) return
    if (armedDeleteId === id) {
      armedDeleteId = ""
      message = ""
      run(["delete", id])
      return
    }
    armedDeleteId = id
    var p = presets.filter(function(x) { return x.id === id })[0]
    showMessage(tr.t("confirm.delete").arg(p ? p.name : id), true)
    disarmTimer.restart()
  }

  function movePreset(dy) {
    if (selectedIndex < 0 || selectedIndex >= presets.length) return
    var target = Math.max(0, Math.min(presets.length - 1, selectedIndex + dy))
    if (target === selectedIndex) return
    run(["move", presets[selectedIndex].id, String(dy)])
    selectedIndex = target
  }

  function restoreHidden() {
    run(["restore-hidden"], function(ok) { if (ok) showMessage(tr.t("msg.restored"), false) })
  }

  function editFile() {
    if (!model.config) return
    Quickshell.execDetached(["omarchy-launch-editor", model.config])
    root.close()
  }

  function moveCursor(dy) {
    if (presets.length === 0) return
    if (!cursorActive) { cursorActive = true; return }
    selectedIndex = Math.max(0, Math.min(presets.length - 1, selectedIndex + dy))
    armedDeleteId = ""
  }

  // ---------------------------------------------------------------- editor

  function openEditor(id) {
    if (!id || showProc.running) return
    cancelEdit()
    armedDeleteId = ""
    message = ""
    editorId = id
    editorDirty = false
    editorLeaveArmed = false
    pickerScreen = -1
    expandedKey = ""
    tileScreen = -1
    tilePath = ""
    draftScreens = []
    editing = true
    refocus()
    showProc.command = ["python3", root.ctl, "show", id, "--json"]
    showProc.running = true
  }

  function takeShow(text) {
    var d = null
    try { d = JSON.parse(String(text || "").trim().split("\n").pop()) } catch (e) { d = null }
    if (!d || d.ok === false || !Array.isArray(d.screens)) {
      showMessage((d && d.error) || tr.t("error.failed"), true)
      leaveEditor()
      return
    }
    draftName = d.name || ""
    draftOthers = d.others === "minimize" ? "minimize" : "keep"
    draftFocus = d.focus || ""
    draftUnresolved = d.unresolved || []
    draftScreens = d.screens.map(function(s) {
      return { position: s.position, label: s.label, monitor: s.monitor, apps: s.apps || [], tiles: s.tiles || null }
    })
    draftLoadSeq++
  }

  function leaveEditor() {
    editing = false
    editorId = ""
    editorDirty = false
    editorLeaveArmed = false
    pickerScreen = -1
    expandedKey = ""
    message = ""
    refocus()
    refresh()
  }

  // Leaving with unsaved changes takes a second press, like deleting does.
  function requestLeave() {
    if (editorDirty && !editorLeaveArmed) {
      editorLeaveArmed = true
      showMessage(tr.t("editor.unsaved"), true)
      leaveTimer.restart()
      return
    }
    leaveEditor()
  }

  function touch() {
    editorDirty = true
    editorLeaveArmed = false
  }

  function cloneScreens() { return JSON.parse(JSON.stringify(draftScreens)) }

  function appAt(si, ai, rev) {
    var s = draftScreens[si]
    return (s && s.apps[ai]) || ({})
  }

  function saveEditor() {
    var name = String(draftName).trim()
    if (name === "") { showMessage(tr.t("editor.noName"), true); return }
    var screens = {}
    for (var i = 0; i < draftScreens.length; i++)
      screens[draftScreens[i].position] = { apps: draftScreens[i].apps, tiles: draftScreens[i].tiles || null }
    var payload = { name: name, others: draftOthers, focus: draftFocus, screens: screens }
    run(["save", editorId, "--data", JSON.stringify(payload)], function(ok) {
      if (!ok) return
      showMessage(tr.t("msg.saved").arg(name), false)
      editorDirty = false
      leaveEditor()
    })
  }

  function createEmpty(name) {
    if (newProc.running) return
    cancelEdit()
    var label = String(name || "").trim()
    newProc.command = ["python3", root.ctl, "new", "--json"].concat(label === "" ? [] : ["--name", label])
    newProc.running = true
  }

  function takeNew(text) {
    var r = null
    try { r = JSON.parse(String(text || "").trim().split("\n").pop()) } catch (e) { r = null }
    if (!r || !r.ok) { showMessage((r && r.error) || tr.t("error.failed"), true); return }
    refresh()
    openEditor(r.id)
  }

  function setFocusScreen(position) { draftFocus = position; touch() }
  function setOthers(minimize) { draftOthers = minimize ? "minimize" : "keep"; touch() }

  function togglePicker(si) {
    pickerScreen = pickerScreen === si ? -1 : si
    pickerReplace = false
    pickerFree = false
    pickerBrowser = null
    pickerCustom = false
    pickerQuery = ""
    expandedKey = ""
  }

  function toggleDetails(si, ai) {
    var key = si + ":" + ai
    expandedKey = expandedKey === key ? "" : key
  }

  function addApp(si, app) {
    var s = cloneScreens()
    if (!s[si]) return
    if (pickerFree && !s[si].tiles) {
      // First app of an empty screen laid out freely: it is the one tile.
      s[si].apps = []
      s[si].tiles = app
      draftScreens = s
      pickerScreen = -1
      pickerFree = false
      tileScreen = si
      tilePath = ""
      touch()
      refocus()
      return
    }
    if (s[si].tiles) {
      if (pickerReplace) replaceTile(si, selectedPath(si), app)
      else addTile(si, app)
      pickerScreen = -1
      refocus()
      return
    }
    var same = s[si].apps.filter(function(a) { return a.exec === app.exec })[0]
    if (same) same.count = Math.min(maxCount, (same.count || 1) + 1)
    else s[si].apps.push(app)
    draftScreens = s
    pickerScreen = -1
    expandedKey = ""
    touch()
    refocus()
  }

  function removeApp(si, ai) {
    var s = cloneScreens()
    s[si].apps.splice(ai, 1)
    draftScreens = s
    expandedKey = ""
    touch()
  }

  // dir -1 / +1: to the screen on the left / right. The app lands last there.
  function sendApp(si, ai, dir) {
    var target = si + dir
    if (target < 0 || target >= draftScreens.length) return
    var s = cloneScreens()
    var app = s[si].apps.splice(ai, 1)[0]
    if (s[target].tiles) {
      // A free layout has one window per tile: each window takes half of the last tile.
      var tree = s[target].tiles
      for (var i = 0; i < Math.max(1, Number(app.count || 1)); i++) {
        var rects = tileRects(tree)
        var last = rects[rects.length - 1].path
        if (rects.length >= maxTiles || last.length >= 8) { showMessage(tr.t("tile.tooMany"), true); return }
        var leaf = cloneOf(app)
        delete leaf.count
        tree = treeWithTile(tree, last, leaf, target)
      }
      s[target].tiles = tree
    } else {
      s[target].apps.push(app)
    }
    draftScreens = s
    expandedKey = ""
    touch()
  }

  function shiftApp(si, ai, dy) {
    var to = ai + dy
    var s = cloneScreens()
    if (to < 0 || to >= s[si].apps.length) return
    s[si].apps.splice(to, 0, s[si].apps.splice(ai, 1)[0])
    draftScreens = s
    expandedKey = ""
    touch()
  }

  function setCount(si, ai, n) {
    var s = cloneScreens()
    var app = s[si].apps[ai]
    if (!app) return
    app.count = Math.max(1, Math.min(maxCount, n))
    if (app.count === 1) delete app.count
    draftScreens = s
    touch()
  }

  // Typing must not rebuild the rows (the field would lose focus), so the app is
  // changed in place and only the counter tells the labels to look again.
  function setField(si, ai, field, value) {
    var app = draftScreens[si] && draftScreens[si].apps[ai]
    if (!app) return
    var v = String(value)
    if (v === "") delete app[field]
    else app[field] = v
    draftRev++
    touch()
  }

  // ---- Free layout: a tree of splits where every tile is one window. A split
  // puts its "b" side to the right of ("right") or below ("down") its "a" side.

  function isSplit(node) { return !!node && node.split !== undefined }
  function cloneOf(value) { return JSON.parse(JSON.stringify(value)) }

  function nodeAt(tree, path) {
    var n = tree
    for (var i = 0; i < path.length; i++) {
      if (!isSplit(n)) return null
      n = path.charAt(i) === "a" ? n.a : n.b
    }
    return n
  }

  // The tree with the node at `path` replaced by fn(node).
  function withNode(tree, path, fn) {
    var t = cloneOf(tree)
    if (path === "") return fn(t)
    var parent = nodeAt(t, path.slice(0, -1))
    var key = path.charAt(path.length - 1)
    parent[key] = fn(parent[key])
    return t
  }

  // Every tile as a fraction of its screen: [{ path, app, x, y, w, h }].
  function tileRects(tree) {
    var out = []
    function walk(n, path, x, y, w, h) {
      if (!isSplit(n)) { out.push({ path: path, app: n, x: x, y: y, w: w, h: h }); return }
      var r = n.ratio === undefined ? 0.5 : Math.max(0.1, Math.min(0.9, n.ratio))
      if (n.split === "down") {
        walk(n.a, path + "a", x, y, w, h * r)
        walk(n.b, path + "b", x, y + h * r, w, h * (1 - r))
      } else {
        walk(n.a, path + "a", x, y, w * r, h)
        walk(n.b, path + "b", x + w * r, y, w * (1 - r), h)
      }
    }
    if (tree) walk(tree, "", 0, 0, 1, 1)
    return out
  }

  // The tile that is selected on screen `si`, or the last one if none is.
  function selectedPath(si) {
    var tree = draftScreens[si] && draftScreens[si].tiles
    if (!tree) return ""
    if (tileScreen === si) {
      var n = nodeAt(tree, tilePath)
      if (n && !isSplit(n)) return tilePath
    }
    var rects = tileRects(tree)
    return rects.length ? rects[rects.length - 1].path : ""
  }

  function selectTile(si, path) { tileScreen = si; tilePath = path }

  function commitTree(si, tree, path) {
    var s = cloneScreens()
    s[si].tiles = tree
    draftScreens = s
    tileScreen = si
    tilePath = path
    touch()
  }

  // Equal columns, left to right, one per window.
  function treeFromApps(apps) {
    var leaves = []
    apps.forEach(function(a) {
      var n = Math.max(1, Number(a.count || 1))
      for (var i = 0; i < n; i++) { var c = cloneOf(a); delete c.count; leaves.push(c) }
    })
    leaves = leaves.slice(0, maxTiles)
    function build(i) {
      if (i === leaves.length - 1) return leaves[i]
      var ratio = Math.round(1000 / (leaves.length - i)) / 1000
      var node = { split: "right", a: leaves[i], b: build(i + 1) }
      if (Math.abs(ratio - 0.5) > 0.0005) node.ratio = ratio
      return node
    }
    return leaves.length ? build(0) : null
  }

  // Identical neighbouring tiles fold back into one app with a count.
  function appsFromTree(tree) {
    var out = []
    tileRects(tree).forEach(function(r) {
      var app = cloneOf(r.app)
      delete app.count
      var last = out[out.length - 1]
      var lastKey = last ? JSON.stringify(Object.assign({}, last, { count: undefined })) : ""
      if (last && lastKey === JSON.stringify(Object.assign({}, app, { count: undefined }))) last.count = (last.count || 1) + 1
      else out.push(app)
    })
    return out
  }

  function enableTiles(si) {
    var s = cloneScreens()
    if (!s[si] || s[si].tiles) return
    var tree = treeFromApps(s[si].apps)
    if (!tree) {
      // Nothing on this screen yet: ask for the first app, which becomes the first tile.
      pickerScreen = si
      pickerReplace = false
      pickerFree = true
      pickerBrowser = null
      pickerCustom = false
      pickerQuery = ""
      return
    }
    s[si].apps = []
    s[si].tiles = tree
    draftScreens = s
    pickerScreen = -1
    expandedKey = ""
    tileScreen = si
    tilePath = ""
    tilePath = selectedPath(si)
    touch()
  }

  function disableTiles(si) {
    var s = cloneScreens()
    s[si].apps = appsFromTree(s[si].tiles)
    s[si].tiles = null
    draftScreens = s
    pickerScreen = -1
    touch()
  }

  function splitTile(si, path, direction) {
    var tree = draftScreens[si].tiles
    if (tileRects(tree).length >= maxTiles || path.length >= 8) { showMessage(tr.t("tile.tooMany"), true); return }
    var next = withNode(tree, path, function(n) { return { split: direction, a: n, b: cloneOf(n) } })
    commitTree(si, next, path + "b")
  }

  function removeTile(si, path) {
    if (path === "") return
    var parent = path.slice(0, -1)
    var key = path.charAt(path.length - 1)
    commitTree(si, withNode(draftScreens[si].tiles, parent, function(p) { return key === "a" ? p.b : p.a }), parent)
  }

  // Grow (delta > 0) or shrink the tile by moving the edge it shares with its sibling.
  function resizeTile(si, path, delta) {
    if (path === "") return
    var parent = path.slice(0, -1)
    var key = path.charAt(path.length - 1)
    var next = withNode(draftScreens[si].tiles, parent, function(p) {
      var r = p.ratio === undefined ? 0.5 : p.ratio
      r = key === "a" ? r + delta : r - delta
      r = Math.max(0.1, Math.min(0.9, Math.round(r * 100) / 100))
      if (Math.abs(r - 0.5) < 0.001) delete p.ratio
      else p.ratio = r
      return p
    })
    commitTree(si, next, path)
  }

  function replaceTile(si, path, app) {
    commitTree(si, withNode(draftScreens[si].tiles, path, function() { return app }), path)
  }

  // The tree with `app` given half of the tile at `path`, along that tile's longer side.
  function treeWithTile(tree, path, app, si) {
    var rect = tileRects(tree).filter(function(r) { return r.path === path })[0]
    var mon = monitors[si] || ({ width: 16, height: 9 })
    var wide = !rect || rect.w * mon.width >= rect.h * mon.height
    return withNode(tree, path, function(n) { return { split: wide ? "right" : "down", a: n, b: app } })
  }

  // A new app takes half of the selected tile, along its longer side.
  function addTile(si, app) {
    var path = selectedPath(si)
    if (tileRects(draftScreens[si].tiles).length >= maxTiles || path.length >= 8) { showMessage(tr.t("tile.tooMany"), true); return }
    commitTree(si, treeWithTile(draftScreens[si].tiles, path, app, si), path + "b")
  }

  // The tile under a point given as fractions of the screen, or null.
  function tileAtPoint(tree, fx, fy) {
    var hit = tileRects(tree).filter(function(r) { return fx >= r.x && fx <= r.x + r.w && fy >= r.y && fy <= r.y + r.h })
    return hit.length ? hit[0] : null
  }

  // Where a drop lands on a tile: the middle swaps, a side puts the dragged tile beside it.
  function dropZone(rect, fx, fy) {
    var u = (fx - rect.x) / rect.w
    var v = (fy - rect.y) / rect.h
    if (u > 0.25 && u < 0.75 && v > 0.25 && v < 0.75) return "center"
    var d = { left: u, right: 1 - u, top: v, bottom: 1 - v }
    var best = "left"
    ;["right", "top", "bottom"].forEach(function(k) { if (d[k] < d[best]) best = k })
    return best
  }

  // Drag the tile at `from` onto the tile at `to`. zone: center swaps the two;
  // left/right/top/bottom takes `from` out of where it was and puts it beside `to`.
  function moveTile(si, from, to, zone) {
    var tree = draftScreens[si] && draftScreens[si].tiles
    if (!tree || from === to) return
    var src = nodeAt(tree, from)
    var dst = nodeAt(tree, to)
    if (!src || !dst || isSplit(src) || isSplit(dst)) return

    if (zone === "center") {
      var swapped = withNode(withNode(tree, from, function() { return cloneOf(dst) }), to, function() { return cloneOf(src) })
      commitTree(si, swapped, to)
      return
    }

    var marked = withNode(tree, to, function(n) { n.__dst = true; return n })
    marked = withNode(marked, from, function() { return { __src: true } })
    // Take the dragged tile out: its sibling takes over the split it leaves.
    function without(n) {
      if (!isSplit(n)) return n.__src ? null : n
      var a = without(n.a), b = without(n.b)
      if (a === null) return b
      if (b === null) return a
      return Object.assign({}, n, { a: a, b: b })
    }
    var rest = without(marked)
    var moved = cloneOf(src)
    moved.__moved = true
    var side = zone === "left" || zone === "top"
    var direction = zone === "left" || zone === "right" ? "right" : "down"
    function place(n) {
      if (isSplit(n)) return Object.assign({}, n, { a: place(n.a), b: place(n.b) })
      if (!n.__dst) return n
      delete n.__dst
      return { split: direction, a: side ? moved : n, b: side ? n : moved }
    }
    var next = place(rest)
    var rects = tileRects(next)
    if (rects.some(function(r) { return r.path.length > 8 })) { showMessage(tr.t("tile.tooMany"), true); return }
    var landed = ""
    rects.forEach(function(r) {
      if (r.app.__moved) { landed = r.path; delete r.app.__moved }
    })
    commitTree(si, next, landed)
  }

  function pickReplace(si) {
    pickerScreen = si
    pickerReplace = true
    pickerFree = false
    pickerBrowser = null
    pickerCustom = false
    pickerQuery = ""
  }

  function escapeRegex(text) { return String(text).replace(/[^A-Za-z0-9_]/g, "\\$&") }

  // A desktop entry becomes an app of the preset: the command to launch it and,
  // when the entry names its window class, how to recognise it once open.
  function appFromEntry(e) {
    if (e.lib) {
      var own = { name: String(e.name), exec: String(e.exec) }
      ;["class", "title", "icon"].forEach(function(k) { if (e[k]) own[k] = String(e[k]) })
      return own
    }
    var command = String(e.execString || "").replace(/\s*%[fFuUdDnNickvm](?=\s|$)/g, "").replace(/\s*@@[uU]?(?=\s|$)/g, "").trim()
    var app = { name: String(e.name || e.id), exec: command }
    if (e.runInTerminal) {
      // Same launcher Omarchy's own menu uses: the window is named org.omarchy.<command>.
      var first = command.split(/\s+/)[0].split("/").pop()
      app.exec = "omarchy-launch-tui " + command
      app["class"] = "^" + escapeRegex("org.omarchy." + first) + "$"
    } else if (e.startupClass) {
      app["class"] = "^" + escapeRegex(e.startupClass) + "$"
    }
    if (e.icon) app.icon = String(e.icon)
    return app
  }

  // ---- Browsers: the user says which address the page opens on.

  // "youtube.com/watch" or "https://youtube.com/watch" -> a full http(s) address, or "" if it is not one.
  function normalizeUrl(text) {
    var t = String(text || "").trim()
    if (t === "" || /\s/.test(t)) return ""
    if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(t)) t = "https://" + t
    return /^https?:\/\/[^\/?#\s]+/i.test(t) ? t : ""
  }

  function shellQuote(text) {
    var t = String(text)
    return /^[A-Za-z0-9_@%+=:,.\/-]+$/.test(t) ? t : "'" + t.replace(/'/g, "'\\''") + "'"
  }

  // "env A=1 setsid foot -e htop" -> "foot": the program a command runs, for a default name.
  function programName(command) {
    var wrappers = ["uwsm-app", "uwsm", "app", "--", "setsid", "exec", "env", "nohup", "systemd-run", "-f", "--fork"]
    var tokens = String(command || "").trim().split(/\s+/)
    for (var i = 0; i < tokens.length; i++) {
      var t = tokens[i].replace(/^['"]+|['"]+$/g, "")
      var base = t.split("/").pop()
      if (t === "" || wrappers.indexOf(base) >= 0 || (t.indexOf("=") >= 0 && t.charAt(0) !== "-")) continue
      return base
    }
    return "app"
  }

  function hostOf(url) {
    var m = /^https?:\/\/([^\/?#:]+)/i.exec(String(url))
    return m ? m[1].replace(/^www\./i, "") : String(url)
  }

  function isBrowserEntry(e) {
    if (!e || e.lib) return false
    if (String(e.categories || "").indexOf("WebBrowser") >= 0) return true
    return /(^|[\/ -])(google-chrome|chromium|firefox|brave|vivaldi|microsoft-edge|opera|zen|librewolf|helium)/i.test(String(e.execString || ""))
  }

  // Chromium-based browsers can open an address as a web app; others only as a window.
  function canBeWebapp(e) {
    return /chrom|chrome|brave|edge|opera|vivaldi|helium/i.test(String(e.execString || "") + " " + String(e.id || ""))
  }

  // `url` is "" for a plain browser window with no address: the browser opens on its own start page.
  function appFromBrowser(e, url, webapp) {
    if (url === "") {
      var blank = appFromEntry(e)
      blank.name = String(e.name)
      blank.exec = blank.exec + " --new-window"
      return blank
    }
    var host = hostOf(url)
    if (webapp) {
      var app = { name: host, exec: "omarchy-launch-webapp " + shellQuote(url) }
      if (e.icon) app.icon = String(e.icon)
      return app
    }
    var base = appFromEntry(e)
    base.name = String(e.name) + " · " + host
    base.exec = base.exec + " --new-window " + shellQuote(url)
    return base
  }

  function beginBrowser(e) {
    pickerUrl = ""
    pickerWebapp = canBeWebapp(e)
    pickerBrowser = e
  }

  function cancelBrowser() { pickerBrowser = null }

  // `typed` is what the address field holds right now; it is the source of truth.
  function confirmBrowser(si, typed) {
    var text = String(typed !== undefined ? typed : pickerUrl).trim()
    var url = text === "" ? "" : normalizeUrl(text)
    if (!pickerBrowser || (text !== "" && url === "")) { showMessage(tr.t("browser.badUrl"), true); return false }
    var app = appFromBrowser(pickerBrowser, url, url !== "" && pickerWebapp && canBeWebapp(pickerBrowser))
    pickerBrowser = null
    addApp(si, app)
    return true
  }

  // A picker choice: browsers ask for an address first, anything else is added at once.
  function chooseEntry(si, e) {
    if (isBrowserEntry(e)) beginBrowser(e)
    else addApp(si, appFromEntry(e))
  }

  function pickerResults(query, rev) {
    var q = String(query || "").trim().toLowerCase()
    // Commands already used by presets (or saved) come first, then installed apps.
    var mine = (model.library || []).filter(function(a) {
      return q === "" || (String(a.name) + " " + String(a.exec)).toLowerCase().indexOf(q) >= 0
    }).map(function(a) {
      return Object.assign({}, a, { lib: true, genericName: tr.t("app.yours") })
    })
    var known = {}
    mine.forEach(function(a) { known[String(a.exec)] = true })
    var values = DesktopEntries.applications.values || []
    var out = []
    for (var i = 0; i < values.length; i++) {
      var e = values[i]
      if (!e || e.noDisplay || !e.execString) continue
      var command = String(e.execString).replace(/\s*%[fFuUdDnNickvm](?=\s|$)/g, "").replace(/\s*@@[uU]?(?=\s|$)/g, "").trim()
      if (known[command]) continue
      var hay = (String(e.name) + " " + String(e.genericName || "") + " " + String(e.id)).toLowerCase()
      if (q !== "" && hay.indexOf(q) < 0) continue
      out.push(e)
    }
    out.sort(function(a, b) {
      var an = String(a.name).toLowerCase(), bn = String(b.name).toLowerCase()
      if (q !== "") {
        var ap = an.indexOf(q) === 0, bp = bn.indexOf(q) === 0
        if (ap !== bp) return ap ? -1 : 1
      }
      return an < bn ? -1 : (an > bn ? 1 : 0)
    })
    return mine.concat(out).slice(0, 80)
  }

  function iconForApp(app) {
    return root.iconFor(app.icon) || root.iconFor(app.name)
  }

  // Digits on a QWERTY row, and the same keys unshifted on AZERTY.
  readonly property var quickKeys: ({
    "1": 0, "2": 1, "3": 2, "4": 3, "5": 4, "6": 5, "7": 6, "8": 7, "9": 8,
    "&": 0, "é": 1, "\"": 2, "'": 3, "(": 4, "-": 5, "è": 6, "_": 7, "ç": 8
  })

  function handleText(t) {
    if (quickKeys[t] !== undefined) { applyIndex(quickKeys[t]); return }
    var k = String(t).toLowerCase()
    if (k === "n" || t === "+") startCapture()
    else if (k === "e") editFile()
    else if (k === "m" && cursorActive && presets[selectedIndex]) openEditor(presets[selectedIndex].id)
    else if (k === "r" && cursorActive && presets[selectedIndex]) startRename(presets[selectedIndex].id)
  }

  // -------------------------------------------------------------- plumbing

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      armedDeleteId = ""
      if (!applyProc.running) message = ""
      if (editing && editorDirty) showMessage(tr.t("editor.restored"), false)
      refresh()
    } else {
      cancelEdit()
      pickerScreen = -1
      pickerBrowser = null
      editorLeaveArmed = false
      // Unsaved changes survive a click outside the panel: reopening it brings them back.
      if (editing && !editorDirty) {
        editing = false
        editorId = ""
      }
    }
  }

  ShellIpc {
    target: "gijux9x.presets"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function apply(id: string): void { root.applyPreset(id) }
    function capture(): void { root.open(); root.startCapture() }
    function edit(id: string): void { root.open(); root.openEditor(id) }
    // Opens the app picker of screen number `screen` (0 = leftmost) in the open editor.
    function pick(screen: int): void { if (root.editing) root.togglePicker(screen) }
    // Switches screen number `screen` of the open editor to the free (tile) layout.
    function free(screen: int): void { if (root.editing) root.enableTiles(screen) }
  }

  Process {
    id: listProc
    command: ["python3", root.ctl, "list", "--json"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.takeList(text) }
  }

  Process {
    id: applyProc
    stdout: StdioCollector { id: applyOut; waitForEnd: true; onStreamFinished: root.takeApplyResult(text) }
    stderr: StdioCollector { id: applyErr; waitForEnd: true }
  }

  Process {
    id: showProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.takeShow(text) }
  }

  Process {
    id: newProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.takeNew(text) }
  }

  Process {
    id: actionProc
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      var after = root.actionAfter
      root.actionAfter = null
      if (exitCode !== 0) {
        Qt.callLater(function() {
          var text = String(actionErr.text || "").trim().replace(/^presetctl: /, "")
          root.showMessage(text || root.tr_failed(), true)
        })
      }
      if (after) after(exitCode === 0)
      if (root.actionQueue.length > 0) Qt.callLater(root.runNext)
      else root.refresh()
    }
  }

  function tr_failed() { return tr.t("error.failed") }

  readonly property var layoutEvents: ({
    openwindow: true, closewindow: true, movewindow: true, movewindowv2: true,
    createworkspace: true, createworkspacev2: true, destroyworkspace: true, destroyworkspacev2: true,
    workspace: true, workspacev2: true, focusedmon: true, focusedmonv2: true, moveworkspace: true, moveworkspacev2: true,
    monitoradded: true, monitoraddedv2: true, monitorremoved: true, monitorremovedv2: true,
    changefloatingmode: true, minimized: true, windowtitlev2: false
  })

  // Windows opening, closing or moving change which preset is active.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      // Title and focus changes fire constantly (a video player, a chat): they do not move windows.
      if (root.opened && event && root.layoutEvents[String(event.name)] === true) refreshDebounce.restart()
    }
  }

  Timer { id: refreshDebounce; interval: 400; onTriggered: root.refresh() }
  Timer { id: doneTimer; interval: 1800; onTriggered: root.doneId = "" }
  Timer { id: closeTimer; interval: 650; onTriggered: root.close() }
  Timer { id: disarmTimer; interval: 3000; onTriggered: { root.armedDeleteId = ""; if (root.messageIsError) root.message = "" } }
  Timer { id: leaveTimer; interval: 3000; onTriggered: { root.editorLeaveArmed = false; if (root.messageIsError) root.message = "" } }
  Timer { id: messageTimer; interval: 6000; onTriggered: if (root.armedDeleteId === "") root.message = "" }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ------------------------------------------------------------ bar button

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.opened ? "" : tr.t("bar.tooltip")
    iconComponent: Component {
      Item {
        ScreensGlyph {
          anchors.centerIn: parent
          unit: button.iconSize / 16
          color: button.foreground
          busy: applyProc.running
        }
      }
    }
    // Left: open the panel. Right: apply the last preset again.
    onPressed: function(b) {
      if (b === Qt.RightButton && root.lastAppliedId !== "") root.applyPreset(root.lastAppliedId)
      else root.toggle()
    }
  }

  // ----------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(root.editing ? 580 : 460))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      implicitHeight: root.editing ? editor.implicitHeight : column.implicitHeight
      reorderable: true
      blocked: root.editMode !== "" || root.editing

      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onReorderRequested: function(dy) { root.cursorActive = true; root.movePreset(dy) }
      onActivateRequested: {
        if (root.cursorActive && root.presets[root.selectedIndex]) root.applyPreset(root.presets[root.selectedIndex].id)
        else if (!root.cursorActive) root.cursorActive = true
      }
      onDeleteRequested: if (root.cursorActive && root.presets[root.selectedIndex]) root.requestDelete(root.presets[root.selectedIndex].id)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { root.handleText(t) }
      // Reopened on a kept editor: the panel gives the keyboard to this catcher, the editor needs it.
      onActiveFocusChanged: if (activeFocus && root.editing) Qt.callLater(function() { if (root.editing) editor.forceActiveFocus() })

      function endEdit() {
        root.cancelEdit()
        keys.forceActiveFocus()
      }

      Connections {
        target: root
        function onRefocus() {
          Qt.callLater(function() {
            if (root.editing) editor.forceActiveFocus()
            else keys.forceActiveFocus()
          })
        }
      }

      Column {
        id: column
        visible: !root.editing
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---------- Hero ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroGlyph.height, heroText.implicitHeight, heroActions.implicitHeight)

          ScreensGlyph {
            id: heroGlyph
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            unit: Style.font.display / 16
            color: root.fg
            busy: applyProc.running
          }

          Column {
            id: heroText
            anchors.left: heroGlyph.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroActions.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            PlainLabel {
              width: parent.width
              text: tr.t("title")
              font.pixelSize: Style.font.title
              font.bold: true
            }
            PlainLabel {
              width: parent.width
              text: root.monitors.length === 0 ? ""
                : (tr.tn("screens", root.monitors.length).arg(Commons.I18n.formatNumber(root.monitors.length))
                   + "  ·  " + root.monitors.map(function(m) { return m.label }).join(" · ")).toUpperCase()
              color: root.dimFg
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.1
            }
          }

          Row {
            id: heroActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Button {
              text: "+ " + tr.t("action.new")
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              active: root.editMode === "capture"
              onClicked: root.editMode === "capture" ? keys.endEdit() : root.startCapture()
            }
            Button {
              text: tr.t("action.file")
              tooltipText: tr.t("action.fileHint")
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              enabled: root.model.config !== ""
              onClicked: root.editFile()
            }
          }
        }

        // ---------- Name field (capture / rename) ----------
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.editMode !== ""

          PlainLabel {
            width: parent.width
            wrapMode: Text.WordWrap
            color: root.dimFg
            font.pixelSize: Style.font.bodySmall
            text: root.editMode === "rename"
              ? tr.t("field.renameHint").arg(root.editSeed)
              : tr.t("field.captureHint")
          }

          Item {
            width: parent.width
            implicitHeight: nameField.implicitHeight

            TextField {
              id: nameField
              anchors.left: parent.left
              anchors.right: editButtons.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              placeholderText: tr.t("field.placeholder")
              foreground: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              maximumLength: 60
              onAccepted: { root.commitEdit(text); keys.forceActiveFocus() }
              Keys.onEscapePressed: function(event) { keys.endEdit(); event.accepted = true }

              function reset() {
                text = root.editSeed
                forceActiveFocus()
                selectAll()
              }
              Connections {
                target: root
                function onEditSeqChanged() { Qt.callLater(nameField.reset) }
              }
              onVisibleChanged: if (visible) Qt.callLater(nameField.reset)
              // Opened straight into capture (IPC or first open): no change to react to.
              Component.onCompleted: if (root.editMode !== "") Qt.callLater(nameField.reset)
            }

            Row {
              id: editButtons
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Button {
                text: root.editMode === "capture" ? tr.t("action.capture") : tr.t("action.save")
                fontSize: Style.font.bodySmall
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                active: true
                onClicked: { root.commitEdit(nameField.text); keys.forceActiveFocus() }
              }
              Button {
                visible: root.editMode === "capture"
                text: tr.t("action.empty")
                tooltipText: tr.t("action.emptyHint")
                fontSize: Style.font.bodySmall
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.createEmpty(nameField.text)
              }
              Button {
                text: tr.t("action.cancel")
                fontSize: Style.font.bodySmall
                foreground: root.fg
                fontFamily: root.fontFamily
                onClicked: keys.endEdit()
              }
            }
          }
        }

        // ---------- Message ----------
        PlainLabel {
          width: parent.width
          visible: text !== ""
          wrapMode: Text.WordWrap
          font.pixelSize: Style.font.bodySmall
          color: root.messageIsError ? Commons.Color.urgent : root.fg
          text: root.model.error ? tr.t("error.config").arg(root.model.error) : root.message
        }

        PanelSeparator { foreground: root.fg }

        // ---------- Presets ----------
        ListView {
          id: list
          width: parent.width
          height: Math.min(contentHeight, Style.space(560))
          visible: root.presets.length > 0
          spacing: Style.space(8)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          model: root.presets
          currentIndex: root.cursorActive ? root.selectedIndex : -1
          onCurrentIndexChanged: if (currentIndex >= 0) Qt.callLater(function() { list.positionViewAtIndex(list.currentIndex, ListView.Contain) })

          delegate: PresetCard {
            width: ListView.view.width
          }
        }

        // ---------- Empty state ----------
        Column {
          width: parent.width
          visible: root.presets.length === 0 && !root.model.error
          spacing: Style.space(6)
          topPadding: Style.space(6)
          bottomPadding: Style.space(6)

          PlainLabel {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: tr.t("empty.title")
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
          PlainLabel {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            color: root.dimFg
            font.pixelSize: Style.font.bodySmall
            text: tr.t("empty.body")
          }
        }

        // ---------- Footer ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(hint.implicitHeight, restoreButton.visible ? restoreButton.implicitHeight : 0)

          PlainLabel {
            id: hint
            anchors.left: parent.left
            anchors.right: restoreButton.visible ? restoreButton.left : parent.right
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: tr.t("hint.keys")
            color: root.dimFg
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Button {
            id: restoreButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: (root.model.hidden || 0) > 0
            text: tr.tn("action.restore", root.model.hidden || 0).arg(Commons.I18n.formatNumber(root.model.hidden || 0))
            fontSize: Style.font.bodySmall
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            onClicked: root.restoreHidden()
          }
        }
      }

      // ================= Editor: what goes where =================
      FocusScope {
        id: editor
        visible: root.editing
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        implicitHeight: editorColumn.implicitHeight
        height: implicitHeight
        Keys.onEscapePressed: function(event) { root.requestLeave(); event.accepted = true }
        Keys.onPressed: function(event) {
          if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_S) {
            root.saveEditor()
            event.accepted = true
          }
        }

        Column {
          id: editorColumn
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          spacing: Style.space(12)

          // ---------- Header ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(backButton.implicitHeight, saveButton.implicitHeight)

            Button {
              id: backButton
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "‹  " + tr.t("action.back")
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.requestLeave()
            }

            PlainLabel {
              anchors.left: backButton.right
              anchors.leftMargin: Style.space(12)
              anchors.right: saveButton.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: tr.t("editor.title") + (root.editorDirty ? "  •" : "")
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Button {
              id: saveButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: tr.t("action.save")
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              active: root.editorDirty
              onClicked: root.saveEditor()
            }
          }

          PlainLabel {
            width: parent.width
            visible: text !== ""
            wrapMode: Text.WordWrap
            font.pixelSize: Style.font.bodySmall
            color: root.messageIsError ? Commons.Color.urgent : root.fg
            text: root.message
          }

          // ---------- Name ----------
          Column {
            width: parent.width
            spacing: Style.space(4)

            PlainLabel {
              width: parent.width
              text: tr.t("editor.name").toUpperCase()
              color: root.dimFg
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.1
            }

            TextField {
              id: nameInput
              width: parent.width
              foreground: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              maximumLength: 60
              placeholderText: tr.t("field.placeholder")
              onTextEdited: { root.draftName = text; root.touch() }
              onAccepted: editor.forceActiveFocus()
              Keys.onEscapePressed: function(event) { editor.forceActiveFocus(); event.accepted = true }

              Connections {
                target: root
                function onDraftLoadSeqChanged() { nameInput.text = root.draftName }
              }
              Component.onCompleted: text = root.draftName
            }
          }

          // ---------- Options ----------
          Toggle {
            width: parent.width
            label: tr.t("editor.others")
            description: tr.t("editor.othersHint")
            checked: root.draftOthers === "minimize"
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: root.setOthers(!checked)
          }

          Item {
            width: parent.width
            implicitHeight: Math.max(focusLabel.implicitHeight, focusRow.implicitHeight)

            PlainLabel {
              id: focusLabel
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, parent.width - focusRow.width - Style.space(8))
              text: tr.t("editor.focus")
              color: root.dimFg
              font.pixelSize: Style.font.bodySmall
            }

            Row {
              id: focusRow
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              Button {
                text: tr.t("editor.focusNone")
                fontSize: Style.font.bodySmall
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                active: root.draftFocus === ""
                onClicked: root.setFocusScreen("")
              }

              Repeater {
                model: root.draftScreens

                Button {
                  required property var modelData
                  text: root.positionLabel(modelData.position)
                  fontSize: Style.font.bodySmall
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  bordered: true
                  active: root.draftFocus === modelData.position
                  onClicked: root.setFocusScreen(modelData.position)
                }
              }
            }
          }

          PanelSeparator { foreground: root.fg }

          // ---------- Screens ----------
          Flickable {
            id: bodyScroll
            width: parent.width
            height: Math.min(bodyColumn.implicitHeight, Style.space(560))
            contentWidth: width
            contentHeight: bodyColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            Column {
              id: bodyColumn
              width: bodyScroll.width
              spacing: Style.space(14)

              Repeater {
                model: root.draftScreens

                ScreenSection { width: bodyColumn.width }
              }

              PlainLabel {
                width: parent.width
                visible: root.draftUnresolved.length > 0
                wrapMode: Text.WordWrap
                color: root.dimFg
                font.pixelSize: Style.font.caption
                text: tr.t("editor.keptScreens").arg(root.draftUnresolved.join(", "))
              }
            }
          }

          PlainLabel {
            width: parent.width
            wrapMode: Text.WordWrap
            color: root.dimFg
            font.pixelSize: Style.font.caption
            text: tr.t("editor.hint")
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ components

  // Three screens, the middle one lit: the widget's icon, drawn so it never
  // depends on a glyph being in the bar font.
  component ScreensGlyph: Item {
    id: glyph
    property real unit: 1
    property color color: Commons.Color.foreground
    property bool busy: false

    width: Math.round(16 * unit)
    height: Math.round(16 * unit)

    Row {
      id: screensRow
      anchors.centerIn: parent
      spacing: Math.max(1, Math.round(glyph.unit))

      Repeater {
        model: [{ w: 4, h: 11, lit: false }, { w: 6, h: 15, lit: true }, { w: 4, h: 11, lit: false }]
        Rectangle {
          required property var modelData
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(3, Math.round(modelData.w * glyph.unit))
          height: Math.max(4, Math.round(modelData.h * glyph.unit))
          radius: Math.max(1, glyph.unit)
          color: modelData.lit ? glyph.color : "transparent"
          border.width: modelData.lit ? 0 : Math.max(1, Math.round(1.25 * glyph.unit))
          border.color: glyph.color
        }
      }

      SequentialAnimation on opacity {
        running: glyph.busy && !Style.reduceMotion
        loops: Animation.Infinite
        alwaysRunToEnd: true
        NumberAnimation { from: 1.0; to: 0.4; duration: Style.duration(520); easing.type: Easing.InOutSine }
        NumberAnimation { from: 0.4; to: 1.0; duration: Style.duration(520); easing.type: Easing.InOutSine }
      }
    }
  }

  component PlainLabel: Text {
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  component PresetCard: CursorSurface {
    id: card
    required property var modelData
    required property int index

    readonly property bool selected: root.cursorActive && root.selectedIndex === index
    readonly property bool applying: root.applyingId === modelData.id
    readonly property bool done: root.doneId === modelData.id
    readonly property bool armed: root.armedDeleteId === modelData.id
    readonly property bool showTools: (cardMouse.containsMouse || selected) && !applying

    hasCursor: selected
    current: modelData.active
    bordered: modelData.active
    foreground: root.fg
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: cardColumn.implicitHeight + Style.space(20)

    MouseArea {
      id: cardMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.selectedIndex = card.index
      }
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) root.openEditor(card.modelData.id)
        else root.applyPreset(card.modelData.id)
      }
    }

    Column {
      id: cardColumn
      x: Style.space(10)
      y: Style.space(10)
      width: card.width - Style.space(20)
      spacing: Style.space(8)

      // Header: number · name · status or tools
      Item {
        width: parent.width
        implicitHeight: Math.max(badge.height, nameBlock.implicitHeight, tools.implicitHeight)

        Rectangle {
          id: badge
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Math.round(Style.font.body * 1.6)
          height: width
          radius: Math.max(2, Style.cornerRadius)
          color: card.modelData.active ? root.fg : "transparent"
          border.width: card.modelData.active ? 0 : 1
          border.color: root.faintFg

          PlainLabel {
            anchors.centerIn: parent
            text: card.modelData.index <= 9 ? Commons.I18n.formatNumber(card.modelData.index) : "·"
            color: card.modelData.active ? Commons.Color.background : root.dimFg
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
        }

        Column {
          id: nameBlock
          anchors.left: badge.right
          anchors.leftMargin: Style.space(10)
          anchors.right: tools.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          PlainLabel {
            width: parent.width
            text: (card.modelData.icon ? card.modelData.icon + "  " : "") + card.modelData.name
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
          PlainLabel {
            width: parent.width
            visible: text !== ""
            text: card.modelData.error
              ? card.modelData.error
              : (card.modelData.unresolved && card.modelData.unresolved.length
                 ? tr.t("error.unresolved").arg(card.modelData.unresolved.join(", "))
                 : card.modelData.description)
            color: card.modelData.error || (card.modelData.unresolved && card.modelData.unresolved.length) ? Commons.Color.urgent : root.dimFg
            font.pixelSize: Style.font.caption
          }
        }

        Row {
          id: tools
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)

          // Status reads first; the tools take its place on hover.
          PlainLabel {
            anchors.verticalCenter: parent.verticalCenter
            visible: !card.showTools || card.applying
            text: card.applying ? tr.t("status.applying").toUpperCase()
              : card.done ? tr.t("status.done").toUpperCase()
              : card.modelData.active ? tr.t("status.active").toUpperCase()
              : (card.modelData.others === "minimize" ? tr.t("badge.minimize") : "")
            color: card.applying || card.done || card.modelData.active ? root.fg : root.dimFg
            font.pixelSize: Style.font.caption
            font.bold: card.applying || card.done || card.modelData.active
            font.letterSpacing: 1.1

            SequentialAnimation on opacity {
              running: card.applying && !Style.reduceMotion
              loops: Animation.Infinite
              alwaysRunToEnd: true
              NumberAnimation { from: 1.0; to: 0.35; duration: Style.duration(480); easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.35; to: 1.0; duration: Style.duration(480); easing.type: Easing.InOutSine }
            }
          }

          Button {
            visible: card.showTools
            text: tr.t("action.modify")
            fontSize: Style.font.caption
            foreground: root.fg
            fontFamily: root.fontFamily
            verticalPadding: Style.space(3)
            horizontalPadding: Style.space(7)
            onClicked: root.openEditor(card.modelData.id)
          }
          Button {
            visible: card.showTools
            text: card.armed ? tr.t("action.confirmDelete") : tr.t("action.delete")
            fontSize: Style.font.caption
            foreground: card.armed ? Commons.Color.urgent : root.fg
            fontFamily: root.fontFamily
            bordered: card.armed
            verticalPadding: Style.space(3)
            horizontalPadding: Style.space(7)
            onClicked: root.requestDelete(card.modelData.id)
          }
        }
      }

      // The screens, left to right, with what goes on each.
      Row {
        id: diagram
        width: parent.width
        spacing: Style.space(6)
        readonly property int count: Math.max(1, (card.modelData.screens || []).length)
        readonly property real boxWidth: (width - spacing * (count - 1)) / count

        Repeater {
          model: card.modelData.screens || []

          Column {
            id: screenColumn
            required property var modelData
            required property int index
            readonly property var mon: root.monitors[index] || ({})
            readonly property bool used: (modelData.tiles || []).length > 0
            width: diagram.boxWidth
            spacing: Style.space(3)

            PlainLabel {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: root.positionLabel(screenColumn.mon.position).toUpperCase()
                + (screenColumn.modelData.workspace ? " · " + tr.t("screen.workspace").arg(screenColumn.modelData.workspace) : "")
              color: screenColumn.used ? root.dimFg : root.faintFg
              font.pixelSize: Math.max(8, Style.font.caption - 1)
              font.bold: true
              font.letterSpacing: 0.8
            }

            // The screen, with each window where the layout will put it.
            Rectangle {
              id: screenBox
              readonly property real pad: Style.space(3)
              readonly property real gap: Style.space(3)
              width: parent.width
              height: Math.round(width * (screenColumn.mon.height || 9) / (screenColumn.mon.width || 16))
              radius: Math.max(2, Math.min(Style.cornerRadius, 6))
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, screenColumn.used ? 0.05 : 0.02)
              border.width: 1
              border.color: screenColumn.used ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.35) : root.faintFg

              PlainLabel {
                anchors.centerIn: parent
                visible: !screenColumn.used
                text: tr.t("screen.untouched")
                color: root.faintFg
                font.pixelSize: Style.font.caption
                font.italic: true
              }

              Repeater {
                model: screenColumn.modelData.tiles || []

                Rectangle {
                  id: tile
                  required property var modelData
                  readonly property real innerW: screenBox.width - screenBox.pad * 2
                  readonly property real innerH: screenBox.height - screenBox.pad * 2
                  readonly property string iconSource: root.iconFor(modelData.icon)
                  readonly property real iconSize: Math.round(Math.max(10, Math.min(22, Math.min(width, height) * 0.5)))
                  readonly property bool roomForName: height >= iconSize + Style.font.caption + Style.space(8) && width >= Style.space(44)

                  x: screenBox.pad + modelData.x * innerW + screenBox.gap / 2
                  y: screenBox.pad + modelData.y * innerH + screenBox.gap / 2
                  width: Math.max(2, modelData.w * innerW - screenBox.gap)
                  height: Math.max(2, modelData.h * innerH - screenBox.gap)
                  radius: Math.max(1, screenBox.radius - 2)
                  // Windows already open are filled; the ones the preset will launch are hollow.
                  color: modelData.present ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.16) : "transparent"
                  border.width: 1
                  border.color: modelData.installed === false ? Commons.Color.urgent
                    : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, modelData.present ? 0.45 : 0.3)

                  Column {
                    anchors.centerIn: parent
                    width: parent.width - Style.space(4)
                    spacing: Style.space(2)
                    opacity: tile.modelData.present ? 1.0 : 0.7

                    Item {
                      anchors.horizontalCenter: parent.horizontalCenter
                      width: tile.iconSize
                      height: tile.iconSize

                      Image {
                        id: tileIcon
                        anchors.fill: parent
                        visible: tile.iconSource !== "" && status !== Image.Error
                        source: tile.iconSource
                        sourceSize.width: tile.iconSize * 2
                        sourceSize.height: tile.iconSize * 2
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        smooth: true
                      }

                      Rectangle {
                        anchors.fill: parent
                        visible: !tileIcon.visible
                        radius: width / 4
                        color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.18)

                        PlainLabel {
                          anchors.centerIn: parent
                          text: String(tile.modelData.name || "?").charAt(0).toUpperCase()
                          font.pixelSize: Math.max(7, Math.round(tile.iconSize * 0.55))
                          font.bold: true
                        }
                      }
                    }

                    PlainLabel {
                      visible: tile.roomForName
                      width: parent.width
                      horizontalAlignment: Text.AlignHCenter
                      text: tile.modelData.installed === false ? tr.t("app.notInstalled").arg(tile.modelData.name) : tile.modelData.name
                      color: tile.modelData.installed === false ? Commons.Color.urgent : root.fg
                      font.pixelSize: Math.max(8, Style.font.caption - 1)
                    }
                  }
                }
              }
            }

            // Monitor stand, so the boxes read as screens.
            Rectangle {
              anchors.horizontalCenter: parent.horizontalCenter
              width: Math.round(parent.width * 0.22)
              height: Math.max(2, Style.space(3))
              radius: height / 2
              color: screenColumn.used ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.35) : root.faintFg
            }
          }
        }
      }
    }
  }

  // One screen of the editor: its apps, and the picker that adds one.
  component ScreenSection: Column {
    id: section
    required property var modelData
    required property int index
    readonly property bool pickerOpen: root.pickerScreen === index
    readonly property bool free: !!modelData.tiles
    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(sectionTitle.implicitHeight, headerButtons.implicitHeight)

      PlainLabel {
        id: sectionTitle
        anchors.left: parent.left
        anchors.right: headerButtons.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        text: (root.positionLabel(section.modelData.position) + "  ·  " + section.modelData.label).toUpperCase()
        color: root.dimFg
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1.1
      }

      Row {
        id: headerButtons
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(6)

        Button {
          text: section.free ? tr.t("layout.auto") : tr.t("layout.free")
          tooltipText: section.free ? tr.t("layout.autoTip") : tr.t("layout.freeTip")
          fontSize: Style.font.bodySmall
          foreground: root.fg
          fontFamily: root.fontFamily
          bordered: true
          active: section.free
          onClicked: section.free ? root.disableTiles(section.index) : root.enableTiles(section.index)
        }

        Button {
          text: section.pickerOpen ? tr.t("action.close") : "+ " + tr.t("action.add")
          fontSize: Style.font.bodySmall
          foreground: root.fg
          fontFamily: root.fontFamily
          bordered: true
          active: section.pickerOpen && !root.pickerReplace && !root.pickerFree
          onClicked: root.togglePicker(section.index)
        }
      }
    }

    Loader {
      width: parent.width
      active: section.pickerOpen
      visible: active
      sourceComponent: AppPicker { screenIndex: section.index }
    }

    Loader {
      width: parent.width
      active: section.free
      visible: active
      sourceComponent: TileDesigner { screenIndex: section.index }
    }

    Repeater {
      model: section.free ? [] : section.modelData.apps

      AppRow {
        width: section.width
        screenIndex: section.index
      }
    }

    PlainLabel {
      width: parent.width
      visible: !section.free && section.modelData.apps.length === 0 && !section.pickerOpen
      text: tr.t("editor.noApps")
      color: root.faintFg
      font.pixelSize: Style.font.bodySmall
      font.italic: true
      wrapMode: Text.WordWrap
    }
  }

  // The screen drawn with its tiles: pick one, then split it, give it another
  // app, make it bigger or smaller, or remove it.
  component TileDesigner: Column {
    id: designer
    property int screenIndex: 0
    readonly property var tree: root.draftScreens[screenIndex] ? root.draftScreens[screenIndex].tiles : null
    readonly property var mon: root.monitors[screenIndex] || ({ width: 16, height: 9 })
    readonly property string selected: root.selectedPath(screenIndex)
    readonly property var rects: root.tileRects(designer.tree)
    spacing: Style.space(8)

    // Drag and drop: press a tile, move past a few pixels, drop it on another one.
    property string pressPath: ""
    property bool dragging: false
    property real startX: 0
    property real startY: 0
    property real px: 0
    property real py: 0
    readonly property var source: dragging ? (rects.filter(function(r) { return r.path === designer.pressPath })[0] || null) : null
    readonly property var hover: dragging ? root.tileAtPoint(designer.tree, px / Math.max(1, box.width), py / Math.max(1, box.height)) : null
    readonly property string zone: hover ? root.dropZone(hover, px / Math.max(1, box.width), py / Math.max(1, box.height)) : ""
    readonly property bool canDrop: !!hover && hover.path !== pressPath

    Rectangle {
      id: box
      width: Math.min(parent.width, Style.space(340))
      height: Math.round(width * designer.mon.height / Math.max(1, designer.mon.width))
      radius: Math.max(2, Math.min(Style.cornerRadius, 6))
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.04)
      border.width: 1
      border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.35)

      Repeater {
        model: designer.rects

        Rectangle {
          id: tile
          required property var modelData
          readonly property bool chosen: modelData.path === designer.selected
          readonly property real gap: Style.space(3)
          readonly property real size: Math.round(Math.max(10, Math.min(24, Math.min(width, height) * 0.45)))
          readonly property string iconSource: root.iconForApp(modelData.app)

          x: modelData.x * box.width + gap / 2
          y: modelData.y * box.height + gap / 2
          width: Math.max(2, modelData.w * box.width - gap)
          height: Math.max(2, modelData.h * box.height - gap)
          radius: Math.max(1, box.radius - 2)
          color: chosen ? root.selectedFill : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.1)
          border.width: chosen ? 2 : 1
          border.color: chosen ? root.fg : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.4)
          opacity: designer.dragging && modelData.path === designer.pressPath ? 0.35 : 1

          Column {
            anchors.centerIn: parent
            width: parent.width - Style.space(4)
            spacing: Style.space(2)

            Item {
              anchors.horizontalCenter: parent.horizontalCenter
              width: tile.size
              height: tile.size

              Image {
                id: tileGlyph
                anchors.fill: parent
                visible: tile.iconSource !== "" && status !== Image.Error
                source: tile.iconSource
                sourceSize.width: tile.size * 2
                sourceSize.height: tile.size * 2
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                smooth: true
              }

              Rectangle {
                anchors.fill: parent
                visible: !tileGlyph.visible
                radius: width / 4
                color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.18)

                PlainLabel {
                  anchors.centerIn: parent
                  text: String(tile.modelData.app.name || "?").charAt(0).toUpperCase()
                  font.pixelSize: Math.max(7, Math.round(tile.size * 0.55))
                  font.bold: true
                }
              }
            }

            PlainLabel {
              visible: tile.height >= tile.size + Style.font.caption + Style.space(8) && tile.width >= Style.space(40)
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: String(tile.modelData.app.name || "")
              font.pixelSize: Math.max(8, Style.font.caption - 1)
            }
          }
        }
      }

      // Where the dragged tile would land.
      Rectangle {
        z: 1
        visible: designer.dragging && designer.canDrop
        readonly property var r: designer.hover || ({ x: 0, y: 0, w: 0, h: 0 })
        readonly property string z2: designer.zone
        x: r.x * box.width + (z2 === "right" ? r.w * box.width / 2 : 0) + Style.space(2)
        y: r.y * box.height + (z2 === "bottom" ? r.h * box.height / 2 : 0) + Style.space(2)
        width: r.w * box.width * (z2 === "left" || z2 === "right" ? 0.5 : 1) - Style.space(4)
        height: r.h * box.height * (z2 === "top" || z2 === "bottom" ? 0.5 : 1) - Style.space(4)
        radius: Math.max(1, box.radius - 2)
        color: Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.28)
        border.width: 2
        border.color: Commons.Color.accent
      }

      // The tile as it is carried.
      Rectangle {
        z: 3
        visible: designer.dragging && !!designer.source
        readonly property var r: designer.source || ({ w: 0.2, h: 0.2, path: "", app: ({}) })
        width: Math.min(Style.space(110), Math.max(Style.space(40), r.w * box.width))
        height: Math.min(Style.space(70), Math.max(Style.space(30), r.h * box.height))
        x: designer.px - width / 2
        y: designer.py - height / 2
        radius: Math.max(1, box.radius - 2)
        color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.22)
        border.width: 1
        border.color: root.fg
        opacity: 0.85

        PlainLabel {
          anchors.centerIn: parent
          width: parent.width - Style.space(6)
          horizontalAlignment: Text.AlignHCenter
          text: String(parent.r.app.name || "")
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      MouseArea {
        z: 2
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: designer.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
        onPressed: function(m) {
          var hit = root.tileAtPoint(designer.tree, m.x / box.width, m.y / box.height)
          designer.pressPath = hit ? hit.path : ""
          designer.startX = m.x
          designer.startY = m.y
          designer.px = m.x
          designer.py = m.y
          if (hit) root.selectTile(designer.screenIndex, hit.path)
        }
        onPositionChanged: function(m) {
          if (!pressed || designer.pressPath === "") return
          designer.px = m.x
          designer.py = m.y
          if (!designer.dragging && Math.abs(m.x - designer.startX) + Math.abs(m.y - designer.startY) > Style.space(8))
            designer.dragging = true
        }
        onReleased: function(m) {
          if (designer.dragging && designer.canDrop)
            root.moveTile(designer.screenIndex, designer.pressPath, designer.hover.path, designer.zone)
          designer.dragging = false
          designer.pressPath = ""
        }
        onCanceled: { designer.dragging = false; designer.pressPath = "" }
      }
    }

    Flow {
      width: parent.width
      spacing: Style.space(5)

      Button {
        text: tr.t("tile.splitRight")
        tooltipText: tr.t("tile.splitRightTip")
        fontSize: Style.font.bodySmall
        foreground: root.fg
        fontFamily: root.fontFamily
        bordered: true
        onClicked: root.splitTile(designer.screenIndex, designer.selected, "right")
      }
      Button {
        text: tr.t("tile.splitDown")
        tooltipText: tr.t("tile.splitDownTip")
        fontSize: Style.font.bodySmall
        foreground: root.fg
        fontFamily: root.fontFamily
        bordered: true
        onClicked: root.splitTile(designer.screenIndex, designer.selected, "down")
      }
      Button {
        text: tr.t("tile.app")
        tooltipText: tr.t("tile.appTip")
        fontSize: Style.font.bodySmall
        foreground: root.fg
        fontFamily: root.fontFamily
        bordered: true
        active: root.pickerScreen === designer.screenIndex && root.pickerReplace
        onClicked: root.pickReplace(designer.screenIndex)
      }
      Button {
        text: tr.t("tile.grow")
        enabled: designer.selected !== ""
        opacity: enabled ? 1 : 0.4
        fontSize: Style.font.bodySmall
        foreground: root.fg
        fontFamily: root.fontFamily
        bordered: true
        onClicked: root.resizeTile(designer.screenIndex, designer.selected, 0.1)
      }
      Button {
        text: tr.t("tile.shrink")
        enabled: designer.selected !== ""
        opacity: enabled ? 1 : 0.4
        fontSize: Style.font.bodySmall
        foreground: root.fg
        fontFamily: root.fontFamily
        bordered: true
        onClicked: root.resizeTile(designer.screenIndex, designer.selected, -0.1)
      }
      Button {
        text: tr.t("tile.remove")
        enabled: designer.selected !== ""
        opacity: enabled ? 1 : 0.4
        fontSize: Style.font.bodySmall
        foreground: Commons.Color.urgent
        fontFamily: root.fontFamily
        bordered: true
        onClicked: root.removeTile(designer.screenIndex, designer.selected)
      }
    }

    PlainLabel {
      width: parent.width
      wrapMode: Text.WordWrap
      text: tr.t("tile.hint")
      color: root.faintFg
      font.pixelSize: Style.font.caption
    }
  }

  // An app on a screen: change how many windows, send it to another screen,
  // reorder it, edit its details, or remove it.
  component AppRow: CursorSurface {
    id: row
    required property var modelData
    required property int index
    property int screenIndex: 0
    readonly property bool expanded: root.expandedKey === row.screenIndex + ":" + row.index
    readonly property var live: root.appAt(row.screenIndex, row.index, root.draftRev)
    readonly property int count: Math.max(1, Number(row.live.count || 1))
    readonly property int screens: root.draftScreens.length
    readonly property int siblings: row.screenIndex < root.draftScreens.length ? root.draftScreens[row.screenIndex].apps.length : 0
    readonly property string iconSource: root.iconForApp(row.live)

    bordered: true
    foreground: root.fg
    implicitHeight: rowColumn.implicitHeight + Style.space(12)

    Column {
      id: rowColumn
      x: Style.space(8)
      y: Style.space(6)
      width: row.width - Style.space(16)
      spacing: Style.space(6)

      Item {
        width: parent.width
        implicitHeight: Math.max(iconBox.height, nameBlock.implicitHeight, controls.implicitHeight)

        Item {
          id: iconBox
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(26)
          height: width

          Image {
            id: rowIcon
            anchors.fill: parent
            visible: row.iconSource !== "" && status !== Image.Error
            source: row.iconSource
            sourceSize.width: width * 2
            sourceSize.height: height * 2
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            smooth: true
          }

          Rectangle {
            anchors.fill: parent
            visible: !rowIcon.visible
            radius: width / 4
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.18)

            PlainLabel {
              anchors.centerIn: parent
              text: String(row.live.name || "?").charAt(0).toUpperCase()
              font.bold: true
            }
          }
        }

        Column {
          id: nameBlock
          anchors.left: iconBox.right
          anchors.leftMargin: Style.space(8)
          anchors.right: controls.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          PlainLabel {
            width: parent.width
            text: String(row.live.name || "")
            font.bold: true
          }
          PlainLabel {
            width: parent.width
            text: String(row.live.exec || "")
            color: root.dimFg
            font.pixelSize: Style.font.caption
          }
        }

        Row {
          id: controls
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(3)

          Button {
            text: "−"
            tooltipText: tr.t("app.fewer")
            enabled: row.count > 1
            opacity: enabled ? 1 : 0.35
            fontSize: Style.font.body
            foreground: root.fg
            fontFamily: root.fontFamily
            verticalPadding: Style.space(3)
            horizontalPadding: Style.space(7)
            onClicked: root.setCount(row.screenIndex, row.index, row.count - 1)
          }
          PlainLabel {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(26)
            horizontalAlignment: Text.AlignHCenter
            text: "×" + row.count
            font.pixelSize: Style.font.bodySmall
            font.bold: row.count > 1
          }
          Button {
            text: "+"
            tooltipText: tr.t("app.more")
            enabled: row.count < root.maxCount
            opacity: enabled ? 1 : 0.35
            fontSize: Style.font.body
            foreground: root.fg
            fontFamily: root.fontFamily
            verticalPadding: Style.space(3)
            horizontalPadding: Style.space(7)
            onClicked: root.setCount(row.screenIndex, row.index, row.count + 1)
          }

          Item { width: Style.space(6); height: 1 }

          Button {
            text: "‹"
            tooltipText: tr.t("app.toLeft")
            enabled: row.screenIndex > 0
            opacity: enabled ? 1 : 0.35
            fontSize: Style.font.body
            foreground: root.fg
            fontFamily: root.fontFamily
            verticalPadding: Style.space(3)
            horizontalPadding: Style.space(7)
            onClicked: root.sendApp(row.screenIndex, row.index, -1)
          }
          Button {
            text: "›"
            tooltipText: tr.t("app.toRight")
            enabled: row.screenIndex < row.screens - 1
            opacity: enabled ? 1 : 0.35
            fontSize: Style.font.body
            foreground: root.fg
            fontFamily: root.fontFamily
            verticalPadding: Style.space(3)
            horizontalPadding: Style.space(7)
            onClicked: root.sendApp(row.screenIndex, row.index, 1)
          }
          Button {
            text: "↑"
            tooltipText: tr.t("app.up")
            enabled: row.index > 0
            opacity: enabled ? 1 : 0.35
            fontSize: Style.font.body
            foreground: root.fg
            fontFamily: root.fontFamily
            verticalPadding: Style.space(3)
            horizontalPadding: Style.space(7)
            onClicked: root.shiftApp(row.screenIndex, row.index, -1)
          }
          Button {
            text: "↓"
            tooltipText: tr.t("app.down")
            enabled: row.index < row.siblings - 1
            opacity: enabled ? 1 : 0.35
            fontSize: Style.font.body
            foreground: root.fg
            fontFamily: root.fontFamily
            verticalPadding: Style.space(3)
            horizontalPadding: Style.space(7)
            onClicked: root.shiftApp(row.screenIndex, row.index, 1)
          }

          Item { width: Style.space(6); height: 1 }

          Button {
            text: "✎"
            tooltipText: tr.t("app.details")
            active: row.expanded
            fontSize: Style.font.body
            foreground: root.fg
            fontFamily: root.fontFamily
            verticalPadding: Style.space(3)
            horizontalPadding: Style.space(7)
            onClicked: root.toggleDetails(row.screenIndex, row.index)
          }
          Button {
            text: "×"
            tooltipText: tr.t("app.remove")
            fontSize: Style.font.body
            foreground: Commons.Color.urgent
            fontFamily: root.fontFamily
            verticalPadding: Style.space(3)
            horizontalPadding: Style.space(7)
            onClicked: root.removeApp(row.screenIndex, row.index)
          }
        }
      }

      Loader {
        width: parent.width
        active: row.expanded
        visible: active
        sourceComponent: Column {
          spacing: Style.space(8)

          DetailField {
            label: tr.t("app.name")
            value: String(row.live.name || "")
            onEdited: function(v) { root.setField(row.screenIndex, row.index, "name", v) }
          }
          DetailField {
            label: tr.t("app.command")
            value: String(row.live.exec || "")
            onEdited: function(v) { root.setField(row.screenIndex, row.index, "exec", v) }
          }
          DetailField {
            label: tr.t("app.class")
            hint: tr.t("app.classHint")
            value: String(row.live["class"] || "")
            onEdited: function(v) { root.setField(row.screenIndex, row.index, "class", v) }
          }
        }
      }
    }
  }

  // A labelled text field of the app details. It owns its text, so rebuilding the
  // labels above while typing never takes the focus away.
  component DetailField: Column {
    id: field
    property string label: ""
    property string hint: ""
    property string value: ""
    signal edited(string value)
    width: parent ? parent.width : 0
    spacing: Style.space(3)

    PlainLabel {
      width: parent.width
      text: field.label
      color: root.dimFg
      font.pixelSize: Style.font.caption
    }
    TextField {
      width: parent.width
      foreground: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      Component.onCompleted: text = field.value
      onTextEdited: field.edited(text)
      onAccepted: editor.forceActiveFocus()
      Keys.onEscapePressed: function(event) { editor.forceActiveFocus(); event.accepted = true }
    }
    PlainLabel {
      width: parent.width
      visible: field.hint !== ""
      text: field.hint
      color: root.faintFg
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  // Search the installed apps, or type a custom command.
  component AppPicker: CursorSurface {
    id: picker
    property int screenIndex: 0
    bordered: true
    foreground: root.fg
    implicitHeight: pickerColumn.implicitHeight + Style.space(16)

    function addCurrent() {
      var hits = root.pickerResults(root.pickerQuery, root.appsRev)
      var i = results.currentIndex
      if (i >= 0 && i < hits.length) root.chooseEntry(picker.screenIndex, hits[i])
    }

    Column {
      id: pickerColumn
      x: Style.space(8)
      y: Style.space(8)
      width: picker.width - Style.space(16)
      spacing: Style.space(8)

      Item {
        width: parent.width
        implicitHeight: Math.max(search.implicitHeight, customButton.implicitHeight)

        TextField {
          id: search
          anchors.left: parent.left
          anchors.right: customButton.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          visible: !root.pickerCustom && !root.pickerBrowser
          foreground: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          placeholderText: tr.t("app.search")
          onTextEdited: root.pickerQuery = text
          onAccepted: picker.addCurrent()
          Keys.onDownPressed: results.currentIndex = Math.min(results.count - 1, results.currentIndex + 1)
          Keys.onUpPressed: results.currentIndex = Math.max(0, results.currentIndex - 1)
          Keys.onEscapePressed: function(event) { root.pickerScreen = -1; editor.forceActiveFocus(); event.accepted = true }
          Component.onCompleted: Qt.callLater(forceActiveFocus)
        }

        PlainLabel {
          anchors.left: parent.left
          anchors.right: customButton.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          visible: root.pickerCustom || !!root.pickerBrowser
          text: root.pickerBrowser ? tr.t("browser.title").arg(String(root.pickerBrowser.name)) : tr.t("app.customTitle")
          font.bold: true
        }

        Button {
          id: customButton
          visible: !root.pickerBrowser
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: root.pickerCustom ? tr.t("app.backToList") : tr.t("app.custom")
          fontSize: Style.font.bodySmall
          foreground: root.fg
          fontFamily: root.fontFamily
          bordered: true
          onClicked: { root.pickerCustom = !root.pickerCustom; if (!root.pickerCustom) Qt.callLater(search.forceActiveFocus) }
        }
      }

      ListView {
        id: results
        width: parent.width
        height: Math.min(contentHeight, Style.space(230))
        visible: !root.pickerCustom && !root.pickerBrowser
        clip: true
        spacing: Style.space(2)
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        model: root.pickerResults(root.pickerQuery, root.appsRev)
        onModelChanged: currentIndex = 0
        onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

        delegate: Rectangle {
          id: hit
          required property var modelData
          required property int index
          width: ListView.view.width
          height: Style.space(34)
          radius: Style.cornerRadius
          color: hitMouse.containsMouse || ListView.isCurrentItem ? root.hoverFill : "transparent"

          MouseArea {
            id: hitMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.chooseEntry(picker.screenIndex, hit.modelData)
          }

          Image {
            id: hitIcon
            anchors.left: parent.left
            anchors.leftMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(22)
            height: width
            source: root.iconFor(hit.modelData.icon) || (hit.modelData.lib ? root.iconFor(hit.modelData.name) : "")
            sourceSize.width: width * 2
            sourceSize.height: height * 2
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            smooth: true
          }

          PlainLabel {
            anchors.left: hitIcon.right
            anchors.leftMargin: Style.space(8)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: String(hit.modelData.name) + (hit.modelData.genericName ? "  ·  " + String(hit.modelData.genericName)
              : (/^omarchy-launch-webapp\b/.test(String(hit.modelData.execString || "")) ? "  ·  " + tr.t("app.webapp") : ""))
          }
        }
      }

      PlainLabel {
        width: parent.width
        visible: !root.pickerCustom && !root.pickerBrowser && results.count === 0
        horizontalAlignment: Text.AlignHCenter
        text: tr.t("app.noMatch")
        color: root.dimFg
        font.pixelSize: Style.font.bodySmall
      }

      // Browser chosen: which address should the page open on?
      Column {
        id: browserForm
        width: parent.width
        visible: !!root.pickerBrowser
        spacing: Style.space(8)

        TextField {
          id: urlField
          width: parent.width
          foreground: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          placeholderText: tr.t("browser.placeholder")
          onTextChanged: root.pickerUrl = text
          onAccepted: root.confirmBrowser(picker.screenIndex, text)
          Keys.onEscapePressed: function(event) { root.cancelBrowser(); event.accepted = true }

          // Each time a browser is picked the field starts empty and takes the keyboard.
          Connections {
            target: root
            function onPickerBrowserChanged() {
              if (!root.pickerBrowser) return
              urlField.text = ""
              Qt.callLater(urlField.forceActiveFocus)
            }
          }
          Component.onCompleted: if (root.pickerBrowser) Qt.callLater(forceActiveFocus)
        }

        Row {
          spacing: Style.space(6)
          visible: !!root.pickerBrowser && root.canBeWebapp(root.pickerBrowser) && urlField.text.trim() !== ""

          Button {
            text: tr.t("browser.webapp")
            tooltipText: tr.t("browser.webappTip")
            fontSize: Style.font.bodySmall
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            active: root.pickerWebapp
            onClicked: root.pickerWebapp = true
          }
          Button {
            text: tr.t("browser.window")
            tooltipText: tr.t("browser.windowTip")
            fontSize: Style.font.bodySmall
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            active: !root.pickerWebapp
            onClicked: root.pickerWebapp = false
          }
        }

        PlainLabel {
          width: parent.width
          wrapMode: Text.WordWrap
          color: root.faintFg
          font.pixelSize: Style.font.caption
          text: urlField.text.trim() === "" ? tr.t("browser.blankHint")
            : (root.pickerBrowser && root.canBeWebapp(root.pickerBrowser) && root.pickerWebapp ? tr.t("browser.webappHint") : tr.t("browser.windowHint"))
        }

        Row {
          spacing: Style.space(6)

          Button {
            text: "+ " + tr.t("action.add")
            fontSize: Style.font.bodySmall
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            active: urlField.text.trim() === "" || root.normalizeUrl(urlField.text) !== ""
            onClicked: root.confirmBrowser(picker.screenIndex, urlField.text)
          }
          Button {
            text: tr.t("action.cancel")
            fontSize: Style.font.bodySmall
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: root.cancelBrowser()
          }
        }
      }

      Column {
        id: customForm
        width: parent.width
        visible: root.pickerCustom
        spacing: Style.space(8)
        property string customName: ""
        property string customExec: ""

        DetailField {
          label: tr.t("app.name")
          onEdited: function(v) { customForm.customName = v }
        }
        DetailField {
          label: tr.t("app.command")
          hint: tr.t("app.commandHint")
          onEdited: function(v) { customForm.customExec = v }
        }
        Button {
          text: "+ " + tr.t("action.add")
          fontSize: Style.font.bodySmall
          foreground: root.fg
          fontFamily: root.fontFamily
          bordered: true
          active: customForm.customExec.trim() !== ""
          enabled: customForm.customExec.trim() !== ""
          onClicked: root.addApp(picker.screenIndex, { name: customForm.customName.trim() || root.programName(customForm.customExec), exec: customForm.customExec.trim() })
        }
      }
    }
  }
}
