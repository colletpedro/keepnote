import Foundation

func runSpringTests() {
    /// Runs a spring at 60 Hz toward `target`; returns (seconds to settle, peak value).
    func run(_ config: SpringConfig, from start: Double = 0, to target: Double = 100,
             precision: Double = 0.25, limit: Double = 5) -> (settle: Double, peak: Double, spring: SpringValue) {
        var spring = SpringValue(value: start)
        var t = 0.0
        var peak = start
        while t < limit {
            spring.advance(by: 1.0 / 60, toward: target, config: config)
            t += 1.0 / 60
            peak = target >= start ? max(peak, spring.value) : min(peak, spring.value)
            if spring.isSettled(at: target, precision: precision) { return (t, peak, spring) }
        }
        return (limit, peak, spring)
    }

    for (name, config) in [("note", SpringConfig.note), ("peek", .peek), ("deck", .deck),
                           ("hover", .hover), ("scroll", .scroll), ("pin", .pin)] {
        let r = run(config)
        expectTrue("\(name): settles on the target", abs(r.spring.value - 100) < 0.25)
        expectTrue("\(name): settles within a second (took \(String(format: "%.2f", r.settle)) s)", r.settle < 1.0)
        expectTrue("\(name): overshoot stays under 8% (peak \(String(format: "%.1f", r.peak)))", r.peak < 108)
    }

    expectTrue("critically damped never overshoots", run(SpringConfig(response: 0.3, dampingRatio: 1)).peak <= 100.0001)
    expectTrue("underdamped overshoots a little", run(SpringConfig(response: 0.3, dampingRatio: 0.5)).peak > 100.5)
    expectTrue("fade settles quickly", run(.fade, from: 0, to: 1, precision: 0.005).settle < 0.5)
    expectTrue("fade never overshoots 1", run(.fade, from: 0, to: 1, precision: 0.005).peak <= 1.0001)

    // Retargeting keeps the velocity: no stop, no jump.
    var spring = SpringValue(value: 0)
    for _ in 0..<6 { spring.advance(by: 1.0 / 60, toward: 100, config: .note) }
    let before = spring
    expectTrue("in flight before retargeting", before.velocity > 50 && before.value > 1 && before.value < 100)
    var retargeted = before
    retargeted.advance(by: 1.0 / 240, toward: 0, config: .note)
    expectTrue("retarget: position does not jump", abs(retargeted.value - before.value) < 5)
    expectTrue("retarget: velocity carries over", retargeted.velocity > 0)
    for _ in 0..<300 { retargeted.advance(by: 1.0 / 60, toward: 0, config: .note) }
    expectTrue("retarget: settles on the new target", retargeted.isSettled(at: 0, precision: 0.25))

    // Hostile inputs.
    var big = SpringValue(value: 0)
    big.advance(by: 10, toward: 100, config: .deck)
    expectTrue("a huge time step stays finite and sane", big.value.isFinite && abs(big.value) < 1000)
    var still = SpringValue(value: 5)
    still.advance(by: 0, toward: 100, config: .note)
    expectTrue("zero time step changes nothing", still == SpringValue(value: 5))
    var onTarget = SpringValue(value: 42)
    for _ in 0..<60 { onTarget.advance(by: 1.0 / 60, toward: 42, config: .note) }
    expectTrue("on target stays put", onTarget == SpringValue(value: 42))
    expectTrue("settled check needs both position and velocity",
               !SpringValue(value: 100, velocity: 50).isSettled(at: 100, precision: 0.25))
}
