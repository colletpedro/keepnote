import Foundation
import os

/// What happens between a click on a note and the note on screen, for
/// `log show --predicate 'subsystem == "com.keepnote.KeepNote" AND category == "open"'`.
///
/// Every line is "[sequence] attempt note what detail": the sequence orders the
/// lines across notes, the attempt is the number a click got and every later
/// line about that note carries until the next click on it. Ids are shortened
/// and nothing of a note's content is ever written.
enum OpenLog {
    private static let logger = Logger(subsystem: "com.keepnote.KeepNote", category: "open")
    /// How loud. While the open bug is being chased the lines are at the
    /// default level, which `log show` prints and keeps; afterwards they go
    /// to `.debug`, where they say nothing unless asked for.
    static let level: OSLogType = .default

    private static let lock = NSLock()
    private static var sequence = 0
    private static var attempt = 0
    private static var attempts: [UUID: Int] = [:]

    /// A click, a key, an action: a new attempt at opening `id`, from `surface`.
    @discardableResult
    static func click(_ surface: String, _ id: UUID, _ detail: String = "") -> Int {
        lock.lock()
        attempt += 1
        attempts[id] = attempt
        lock.unlock()
        event("click", id, "\(surface) \(detail)")
        return attempt
    }

    static func event(_ what: String, _ id: UUID?, _ detail: String = "") {
        lock.lock()
        sequence += 1
        let line = sequence
        let number = id.flatMap { attempts[$0] } ?? 0
        lock.unlock()
        let note = id.map { String($0.uuidString.prefix(8)) } ?? "-"
        logger.log(level: level, "[\(line, privacy: .public)] a\(number, privacy: .public) \(note, privacy: .public) \(what, privacy: .public) \(detail, privacy: .public)")
    }
}

// MARK: - The mouse, as the app receives it

import AppKit
import ObjectiveC

extension OpenLog {
    private static var pressAt: NSPoint?
    private static var monitor: Any?

    /// Every left press, release and the first drag past 3 pt in any of the
    /// app's windows, with what was under the pointer and, for a list, which
    /// row was selected then and a moment later. A click the list never turns
    /// into a selection leaves a press here and nothing else. Only classes and
    /// numbers are written, never a note's text.
    @MainActor
    static func installMouseMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { event in
            describe(event)
            return event
        }
    }

    @MainActor
    private static func describe(_ event: NSEvent) {
        guard let window = event.window else { return }
        let owner = window.delegate.map { String(describing: type(of: $0)).prefix(32) } ?? "-"
        let hit = window.contentView?.superview?.hitTest(event.locationInWindow)
        var chain: [String] = []
        var table: NSTableView?
        var view = hit
        while let current = view {
            if chain.count < 5 {
                let own = class_getMethodImplementation(type(of: current), #selector(NSResponder.mouseDown(with:)))
                let base = class_getMethodImplementation(NSResponder.self, #selector(NSResponder.mouseDown(with:)))
                chain.append(String(String(describing: type(of: current)).prefix(30)) + (own != base ? "*" : ""))
            }
            if table == nil, let found = current as? NSTableView { table = found }
            view = current.superview
        }
        let where_ = "win=\(owner) key=\(window.isKeyWindow) active=\(NSApp.isActive) hit=\(chain.joined(separator: ">"))"
        switch event.type {
        case .leftMouseDown:
            pressAt = event.locationInWindow
            let rows = table.map { table -> String in
                let local = table.convert(event.locationInWindow, from: nil)
                let row = table.row(at: local)
                let frame = row >= 0 ? table.rect(ofRow: row) : .zero
                let allowed = row >= 0 ? (table.delegate?.tableView?(table, shouldSelectRow: row)).map { String($0) } ?? "n/a" : "-"
                return "rows=\(table.selectedRowIndexes.map { String($0) }.joined(separator: ",")) clicked=\(row) inRow=(\(Int(local.x - frame.minX)),\(Int(local.y - frame.minY))) rowSize=(\(Int(frame.width)),\(Int(frame.height))) shouldSelect=\(allowed) enabled=\(table.isEnabled) first=\(window.firstResponder.map { String(String(describing: type(of: $0)).prefix(28)) } ?? "-")"
            } ?? "no-table"
            Self.event("mouse-down", nil, "clicks=\(event.clickCount) \(rows) \(where_)")
            if let table { swizzleMouseDown(of: type(of: table)) }
            if let table {
                let before = table.selectedRowIndexes
                for ms in [30, 80] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) {
                        Self.event("mouse-down+\(ms)ms", nil, "rowsNow=\(table.selectedRowIndexes.map { String($0) }.joined(separator: ","))")
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    Self.event("mouse-down+250ms", nil, "rowsBefore=\(before.map { String($0) }.joined(separator: ",")) rowsNow=\(table.selectedRowIndexes.map { String($0) }.joined(separator: ","))")
                }
            }
        case .leftMouseUp:
            let moved = pressAt.map { Int(hypot(event.locationInWindow.x - $0.x, event.locationInWindow.y - $0.y)) } ?? -1
            pressAt = nil
            Self.event("mouse-up", nil, "moved=\(moved)pt \(where_)")
        default:
            if let start = pressAt, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 3 {
                Self.event("mouse-drag", nil, "over=3pt \(where_)")
                pressAt = nil
            }
        }
    }
}

// MARK: - Whether the table itself is given the press

private var swizzled: Set<ObjectIdentifier> = []

extension OpenLog {
    /// Wraps `mouseDown(with:)` of the list's table class, for that class only:
    /// a press that reaches it says so, with the selection before and after it
    /// returns. A press taken by a view above the table never says anything.
    @MainActor
    fileprivate static func swizzleMouseDown(of cls: NSTableView.Type) {
        guard swizzled.insert(ObjectIdentifier(cls)).inserted,
              let method = class_getInstanceMethod(cls, #selector(NSResponder.mouseDown(with:))) else { return }
        typealias Original = @convention(c) (AnyObject, Selector, NSEvent) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let selector = #selector(NSResponder.mouseDown(with:))
        let wrapper: @convention(block) (NSTableView, NSEvent) -> Void = { table, event in
            let row = table.row(at: table.convert(event.locationInWindow, from: nil))
            let before = table.selectedRowIndexes.map { String($0) }.joined(separator: ",")
            OpenLog.event("table-mouseDown", nil, "row=\(row) before=\(before)")
            original(table, selector, event)
            OpenLog.event("table-mouseDown-returned", nil, "row=\(row) after=\(table.selectedRowIndexes.map { String($0) }.joined(separator: ","))")
        }
        class_replaceMethod(cls, selector, imp_implementationWithBlock(wrapper), method_getTypeEncoding(method))
    }
}
