import Foundation

/// A damped spring, as plain numbers.
///
/// `response` is roughly how long, in seconds, the spring takes to travel most
/// of the way; `dampingRatio` is 1 for no overshoot and lower for a bounce
/// (0.8 overshoots a little, which is what makes a card feel like it has
/// weight). Mass is 1: stiffness is `(2π / response)²` and damping
/// `4π · ratio / response`.
struct SpringConfig: Equatable {
    var response: Double
    var dampingRatio: Double

    var stiffness: Double {
        let omega = 2 * Double.pi / response
        return omega * omega
    }

    var damping: Double {
        4 * Double.pi * dampingRatio / response
    }

    /// A note sliding out of the deck and folding back into it.
    static let note = SpringConfig(response: 0.36, dampingRatio: 0.84)
    /// The peek under the cursor: quick, barely any overshoot.
    static let peek = SpringConfig(response: 0.28, dampingRatio: 0.88)
    /// A tab dealing out of the stack.
    static let deck = SpringConfig(response: 0.32, dampingRatio: 0.80)
    /// A tab lifting under the cursor.
    static let hover = SpringConfig(response: 0.22, dampingRatio: 0.80)
    /// The deck following a scroll that came as a coarse wheel notch.
    static let scroll = SpringConfig(response: 0.2, dampingRatio: 0.92)
    /// Lifting a note off the edge or putting it back.
    static let pin = SpringConfig(response: 0.40, dampingRatio: 0.82)
    /// Reduce Motion: no travel, just a short fade. Critically damped, so the
    /// opacity never overshoots past 1.
    static let fade = SpringConfig(response: 0.08, dampingRatio: 1)
}

/// One animated number: where it is and how fast it is going.
///
/// Re-aiming it mid-flight is just `advance` with a different target — the
/// velocity carries over, so an interrupted animation bends toward its new goal
/// instead of stopping and restarting.
struct SpringValue: Equatable {
    var value: Double
    var velocity: Double = 0

    /// Steps in slices of at most 1/240 s, so a long frame (a busy main thread)
    /// cannot make the integration blow up.
    mutating func advance(by dt: Double, toward target: Double, config: SpringConfig) {
        guard dt > 0 else { return }
        let maxSlice = 1.0 / 240
        var remaining = min(dt, 0.25)
        let k = config.stiffness
        let c = config.damping
        while remaining > 0 {
            let h = min(remaining, maxSlice)
            let acceleration = k * (target - value) - c * velocity
            velocity += acceleration * h
            value += velocity * h
            remaining -= h
        }
    }

    func isSettled(at target: Double, precision: Double) -> Bool {
        abs(value - target) < precision && abs(velocity) < precision * 8
    }
}
