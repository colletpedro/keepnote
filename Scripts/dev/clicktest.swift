// Dev only (never shipped): real clicks, read back through Accessibility.
// Posts CGEvent mouse clicks on the rows of KeepNote's note list, then checks
// within 300 ms that the clicked row, and only it, reports AXSelected.
//   clicktest <clicks> [interval-seconds] [outline-title-to-skip=Sidebar]
import AppKit
import ApplicationServices

func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v as AnyObject?
}
func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, "AXChildren") as? [AXUIElement] ?? [] }
func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = attr(e, "AXPosition"), let s = attr(e, "AXSize") else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt); AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}
func find(_ e: AXUIElement, _ pred: (AXUIElement) -> Bool) -> AXUIElement? {
    if pred(e) { return e }
    for c in children(e) { if let f = find(c, pred) { return f } }
    return nil
}
func rows(_ list: AXUIElement) -> [AXUIElement] { children(list).filter { attr($0, "AXRole") as? String == "AXRow" } }

guard AXIsProcessTrusted() else { print("NOT TRUSTED"); exit(2) }
let args = CommandLine.arguments
let clicks = Int(args.count > 1 ? args[1] : "30")!
let interval = Double(args.count > 2 ? args[2] : "1.0")!
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "KeepNote" }) else { print("no app"); exit(2) }
app.activate()
Thread.sleep(forTimeInterval: 0.4)
let ax = AXUIElementCreateApplication(app.processIdentifier)

func noteList() -> AXUIElement? {
    for w in children(ax) where attr(w, "AXRole") as? String == "AXWindow" {
        if let l = find(w, { attr($0, "AXRole") as? String == "AXOutline" && (attr($0, "AXDescription") as? String ?? attr($0, "AXTitle") as? String) != "Sidebar" && !rows($0).isEmpty }) { return l }
    }
    return nil
}
func click(_ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.04)
    let d = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)
    d?.setIntegerValueField(.mouseEventClickState, value: 1); d?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.06)
    let u = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)
    u?.setIntegerValueField(.mouseEventClickState, value: 1); u?.post(tap: .cghidEventTap)
}

var failures = 0, last = -1
var rng = SystemRandomNumberGenerator()
for n in 1...clicks {
    guard let list = noteList() else { print("#\(n) no list"); failures += 1; Thread.sleep(forTimeInterval: interval); continue }
    let rs = rows(list)
    var i = Int.random(in: 0..<rs.count, using: &rng)
    if rs.count > 1 { while i == last { i = Int.random(in: 0..<rs.count, using: &rng) } }
    last = i
    guard let f = frame(rs[i]), let lf = frame(list) else { print("#\(n) no frame"); failures += 1; continue }
    let vis = f.intersection(lf)
    let pt = CGPoint(x: vis.minX + vis.width * 0.35, y: vis.midY)
    click(pt)
    // Within 300 ms: some row selected whose frame holds the click point.
    var ok = false, sel = -1
    let t0 = Date()
    repeat {
        let now = rows(list)
        let selected = now.enumerated().filter { (attr($0.element, "AXSelected") as? Bool) == true }
        sel = selected.first?.offset ?? -1
        if selected.count == 1, let sf = frame(selected[0].element), sf.contains(pt) { ok = true; break }
        Thread.sleep(forTimeInterval: 0.02)
    } while Date().timeIntervalSince(t0) < 0.3
    if !ok { failures += 1 }
    print("#\(n) row \(i) \(ok ? "ok" : "FAIL (selected row \(sel), after \(Int(Date().timeIntervalSince(t0) * 1000)) ms)")")
    Thread.sleep(forTimeInterval: interval)
}
print("FAILURES \(failures)/\(clicks)")
exit(failures == 0 ? 0 : 1)
