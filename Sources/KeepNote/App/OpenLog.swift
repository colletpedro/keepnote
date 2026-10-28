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
    /// `.debug` says nothing unless asked for (`log show --debug`).
    static let level: OSLogType = .debug

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
