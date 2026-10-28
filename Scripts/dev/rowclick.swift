// Dev-only. Posts real mouse clicks (CGEvent) on the rows of the All Notes list
// of a running KeepNote and reads the list's selection through Accessibility.
//
//   rowclick dump  <pid>                 print the window's accessibility tree
//   rowclick run   <pid> <n> [interval]  click n varied rows, check each within 300 ms
//
// Needs the Accessibility permission of the process that runs it. Not shipped.
import ApplicationServices
import AppKit

func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func role(_ e: AXUIElement) -> String { (attr(e, kAXRoleAttribute) as? String) ?? "" }
func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt); AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}
func text(_ e: AXUIElement) -> String {
    for k in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
        if let s = attr(e, k) as? String, !s.isEmpty { return s }
    }
    for c in children(e) { let t = text(c); if !t.isEmpty { return t } }
    return ""
}
func hasHeading(_ e: AXUIElement) -> Bool { role(e) == "AXHeading" || children(e).contains(where: hasHeading) }
func dump(_ e: AXUIElement, _ d: Int, _ max: Int) {
    if d > max { return }
    let f = frame(e).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? ""
    print(String(repeating: "  ", count: d) + role(e), (attr(e, kAXTitleAttribute) as? String) ?? "", f)
    for c in children(e) { dump(c, d + 1, max) }
}
/// The note list: the right-most table of the window (the sidebar's is left of it).
func findTable(_ e: AXUIElement) -> AXUIElement? {
    var all: [AXUIElement] = []
    func walk(_ e: AXUIElement, _ d: Int) {
        let r = role(e)
        if r == "AXTable" || r == "AXOutline" { all.append(e); return }
        if d > 12 { return }
        for c in children(e) { walk(c, d + 1) }
    }
    walk(e, 0)
    return all.filter { (attr($0, kAXRowsAttribute) as? [AXUIElement])?.isEmpty == false }
        .max { (frame($0)?.minX ?? 0) < (frame($1)?.minX ?? 0) }
}

/// Whether the topmost accessibility element at `p`, of any app, lies inside `table`
/// (a note card or another window over the list would otherwise take the click).
func hits(_ table: AXUIElement, at p: CGPoint) -> Bool {
    var el: AXUIElement?
    guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &el) == .success, var cur = el else { return false }
    for _ in 0..<20 {
        if CFEqual(cur, table) { return true }
        guard let par = attr(cur, kAXParentAttribute) else { return false }
        cur = par as! AXUIElement
    }
    return false
}

func click(_ p: CGPoint) {
    let src = CGEventSource(stateID: .hidSystemState)
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(40_000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(60_000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}

let a = CommandLine.arguments
guard a.count >= 3, let pid = pid_t(a[2]) else { print("usage: rowclick dump|run <pid> [n] [interval]"); exit(2) }
guard AXIsProcessTrusted() else { print("NOT TRUSTED for Accessibility"); exit(3) }
let app = AXUIElementCreateApplication(pid)

if a[1] == "dump" {
    for w in (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { dump(w, 0, 9) }
    exit(0)
}

if a[1] == "drag" {
    // Press on the second row, pull it 80 pt down-left, hold 2.5 s (a screenshot is taken then), Esc, release.
    var table: AXUIElement?
    for w in (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { if let t = findTable(w) { table = t; break } }
    guard let t = table, let row = (attr(t, kAXRowsAttribute) as? [AXUIElement])?.dropFirst(1).first, let rf = frame(row) else { exit(4) }
    let src = CGEventSource(stateID: .hidSystemState)
    let p = CGPoint(x: rf.minX + 100, y: rf.midY)
    func post(_ t: CGEventType, _ q: CGPoint) { CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: q, mouseButton: .left)?.post(tap: .cghidEventTap) }
    post(.mouseMoved, p); usleep(100_000); post(.leftMouseDown, p); usleep(100_000)
    for i in 1...16 { post(.leftMouseDragged, CGPoint(x: p.x - CGFloat(i) * 5, y: p.y + CGFloat(i) * 5)); usleep(30_000) }
    print("holding"); fflush(stdout)
    Thread.sleep(forTimeInterval: 2.5)
    for down in [true, false] { CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap) }
    usleep(200_000); post(.leftMouseUp, CGPoint(x: p.x - 80, y: p.y + 80))
    exit(0)
}

if a[1] == "menu" {
    // menu <pid> <item>: open the reading pane's menu button (the one that is not Sort) and press the item.
    func all(_ e: AXUIElement, _ out: inout [AXUIElement]) { if role(e) == "AXMenuButton", (attr(e, kAXTitleAttribute) as? String) != "Sort" { out.append(e) }; children(e).forEach { all($0, &out) } }
    func items(_ e: AXUIElement, _ out: inout [AXUIElement]) { if role(e) == "AXMenuItem" { out.append(e) }; children(e).forEach { items($0, &out) } }
    var bs: [AXUIElement] = []; for w in (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { all(w, &bs) }
    for b in bs {
        AXUIElementPerformAction(b, kAXPressAction as CFString); usleep(600_000)
        var its: [AXUIElement] = []; items(b, &its)
        print("menu button with items:", its.map { (attr($0, kAXTitleAttribute) as? String) ?? "" })
        if let it = its.first(where: { (attr($0, kAXTitleAttribute) as? String) == a[3] }) { AXUIElementPerformAction(it, kAXPressAction as CFString); print("pressed"); exit(0) }
        let esc = CGEventSource(stateID: .hidSystemState); for d in [true, false] { CGEvent(keyboardEventSource: esc, virtualKey: 53, keyDown: d)?.post(tap: .cghidEventTap) }
    }
    print("no such item"); exit(5)
}
if a[1] == "note" {
    // note <pid> <title>: one real click on that note's row in the list.
    func flat(_ e: AXUIElement) -> [String] { var o: [String] = []; if role(e) == "AXStaticText", let v = attr(e, kAXValueAttribute) as? String { o.append(v) }; children(e).forEach { o += flat($0) }; return o }
    for w in (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
        if let t = findTable(w), let r = ((attr(t, kAXRowsAttribute) as? [AXUIElement]) ?? []).first(where: { flat($0).first == a[3] }), let f = frame(r) { click(CGPoint(x: f.minX + f.width * 0.4, y: f.midY)); exit(0) }
    }
    print("not found"); exit(5)
}
if a[1] == "sidebar" {
    // sidebar <pid> <item>: one real click on that sidebar row.
    func walk(_ e: AXUIElement, _ out: inout [AXUIElement]) { if role(e) == "AXOutline" { out.append(e); return }; children(e).forEach { walk($0, &out) } }
    func flat(_ e: AXUIElement) -> [String] { var o: [String] = []; if role(e) == "AXStaticText", let v = attr(e, kAXValueAttribute) as? String { o.append(v) }; children(e).forEach { o += flat($0) }; return o }
    var outs: [AXUIElement] = []
    for w in (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { walk(w, &outs) }
    guard let side = outs.min(by: { (frame($0)?.minX ?? 0) < (frame($1)?.minX ?? 0) }),
          let r = ((attr(side, kAXRowsAttribute) as? [AXUIElement]) ?? []).first(where: { flat($0).first == a[3] }), let f = frame(r) else { print("not found"); exit(5) }
    click(CGPoint(x: f.minX + 60, y: f.midY)); exit(0)
}
if a[1] == "drop" {
    // drop <pid> <note title> <sidebar item>: press on the note's row, pull it onto the sidebar row, release.
    func tables(_ e: AXUIElement) -> [AXUIElement] {
        var all: [AXUIElement] = []
        func walk(_ e: AXUIElement, _ d: Int) { if role(e) == "AXOutline" { all.append(e); return }; if d < 12 { children(e).forEach { walk($0, d + 1) } } }
        walk(e, 0); return all.sorted { (frame($0)?.minX ?? 0) < (frame($1)?.minX ?? 0) }
    }
    func flat(_ e: AXUIElement) -> [String] { var o: [String] = []; if role(e) == "AXStaticText", let v = attr(e, kAXValueAttribute) as? String { o.append(v) }; children(e).forEach { o += flat($0) }; return o }
    guard let w = (attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first(where: { !tables($0).isEmpty }) else { exit(4) }
    let ts = tables(w)
    func find(_ t: AXUIElement, _ name: String) -> (AXUIElement, CGRect)? {
        for r in (attr(t, kAXRowsAttribute) as? [AXUIElement]) ?? [] where flat(r).first == name { if let f = frame(r) { return (r, f) } }
        return nil
    }
    func counts() -> String { ((attr(ts[0], kAXRowsAttribute) as? [AXUIElement]) ?? []).map { flat($0).joined(separator: ":") }.joined(separator: " | ") }
    guard let (_, nf) = find(ts[1], a[3]), let (_, sf) = find(ts[0], a[4]) else { print("row not found"); exit(5) }
    print("before:", counts())
    let src = CGEventSource(stateID: .hidSystemState)
    func post(_ t: CGEventType, _ q: CGPoint) { CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: q, mouseButton: .left)?.post(tap: .cghidEventTap) }
    let from = CGPoint(x: nf.minX + nf.width * 0.4, y: nf.midY), to = CGPoint(x: sf.minX + 60, y: sf.midY)
    post(.mouseMoved, from); usleep(150_000); post(.leftMouseDown, from); usleep(150_000)
    for i in 1...30 { let f = CGFloat(i) / 30; post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f)); usleep(25_000) }
    usleep(400_000); post(.leftMouseUp, to); sleep(1)
    print("after: ", counts())
    exit(0)
}

let n = a.count > 3 ? Int(a[3])! : 30
let interval = a.count > 4 ? Double(a[4])! : 1.0
var rng = SystemRandomNumberGenerator()
var fails = 0, total = 0
var lastIdx = -1
for i in 0..<n {
    var table: AXUIElement?
    for w in (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { if let t = findTable(w) { table = t; break } }
    guard let t = table, let tf = frame(t) else { print("no list found"); exit(4) }
    let rows = (attr(t, kAXRowsAttribute) as? [AXUIElement]) ?? []
    // Rows fully inside the visible list, ignoring section headers (no text) and the last click.
    let cand = rows.enumerated().filter { (j, r) in
        guard let f = frame(r), f.height > 20, tf.contains(CGPoint(x: f.midX, y: f.midY)) else { return false }
        return j != lastIdx && !text(r).isEmpty && !hasHeading(r)
    }
    guard let (idx, row) = cand.randomElement(using: &rng), let rf = frame(row) else { print("no clickable row"); exit(5) }
    lastIdx = idx
    let title = text(row)
    // Aim at a spot of the row that is really the list: a note card may float over its right part.
    guard let p = [0.4, 0.3, 0.2, 0.12, 0.6].map({ CGPoint(x: rf.minX + rf.width * $0, y: rf.midY) }).first(where: { hits(t, at: $0) }) else {
        print(String(format: "%02d SKIP row %d \"%@\" covered by another window", i + 1, idx, String(title.prefix(30)))); lastIdx = idx; continue
    }
    let t0 = Date()
    click(p)
    var ok = false, sel = ""
    while Date().timeIntervalSince(t0) < 0.3 {
        let s = (attr(t, kAXSelectedRowsAttribute) as? [AXUIElement]) ?? []
        sel = s.map(text).joined(separator: "|")
        if s.count == 1 && CFEqual(s[0], row) { ok = true; break }
        usleep(10_000)
    }
    total += 1
    var late = ""
    if !ok {
        fails += 1
        // Late or never: look again for up to 1.5 s more.
        while Date().timeIntervalSince(t0) < 1.8 {
            let s = (attr(t, kAXSelectedRowsAttribute) as? [AXUIElement]) ?? []
            if s.count == 1 && CFEqual(s[0], row) { late = " LATE \(Int(Date().timeIntervalSince(t0) * 1000)) ms"; break }
            usleep(20_000)
        }
        if late.isEmpty { late = " NEVER" }
    }
    print(String(format: "%02d %@ row %d \"%@\" %@", i + 1, ok ? "ok  " : "FAIL", idx, String(title.prefix(30)), ok ? "" : "selected=[\(sel.prefix(40))]\(late)"))
    Thread.sleep(forTimeInterval: interval)
}
print("FAILS \(fails)/\(total)")
