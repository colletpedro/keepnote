import CoreGraphics
import Foundation

/// Whether the cursor on the resting stripe means to open the deck.
///
/// The stripe sits on the screen's right edge, which is also the way to a
/// monitor further right. A cursor that stays on the stripe for the open delay
/// means it; so does one that arrives slowly, the way a hand slows down onto a
/// target. One that crosses fast, on its way somewhere else, does not.
///
/// Times are in seconds on any one clock (the app uses `NSEvent.timestamp`),
/// positions in screen points.
struct DeckIntent {
    /// Below this speed the cursor is arriving, not passing: the deck opens at
    /// once. A flick to the next screen runs at well over a thousand.
    static let slowSpeed: CGFloat = 300
    static let defaultDelay: Double = 0.150
    static let delayRange: ClosedRange<Double> = 0...0.400

    enum Decision: Equatable {
        case open
        /// Ask again at this time if the cursor is still there.
        case wait(until: Double)
        /// The cursor is not on the stripe.
        case idle
    }

    let delay: Double
    private(set) var enteredAt: Double?
    private var last: (time: Double, point: CGPoint)?
    private var slowArrival = false

    init(delay: Double) {
        self.delay = min(max(delay, Self.delayRange.lowerBound), Self.delayRange.upperBound)
    }

    mutating func enter(at point: CGPoint, time: Double) {
        enteredAt = time
        last = (time, point)
        slowArrival = false
    }

    mutating func move(to point: CGPoint, time: Double) {
        guard enteredAt != nil else { return }
        if let last, time > last.time {
            let distance = hypot(point.x - last.point.x, point.y - last.point.y)
            if distance / CGFloat(time - last.time) < Self.slowSpeed { slowArrival = true }
        }
        last = (time, point)
    }

    mutating func exit() {
        enteredAt = nil
        last = nil
        slowArrival = false
    }

    func decision(now: Double) -> Decision {
        guard let enteredAt else { return .idle }
        if delay <= 0 || slowArrival || now - enteredAt >= delay { return .open }
        return .wait(until: enteredAt + delay)
    }
}
