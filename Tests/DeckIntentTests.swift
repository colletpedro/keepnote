import CoreGraphics
import Foundation

func runDeckIntentTests() {
    func point(_ x: CGFloat, _ y: CGFloat = 400) -> CGPoint { CGPoint(x: x, y: y) }

    // Staying on the stripe.
    var dwell = DeckIntent(delay: 0.150)
    expect("intent: nothing before the cursor arrives", "\(dwell.decision(now: 10))", "\(DeckIntent.Decision.idle)")
    dwell.enter(at: point(1430), time: 10)
    expect("intent: a moment after arriving it waits for the delay",
           "\(dwell.decision(now: 10.05))", "\(DeckIntent.Decision.wait(until: 10.15))")
    expect("intent: still there after the delay, it opens", "\(dwell.decision(now: 10.15))", "\(DeckIntent.Decision.open)")

    // Crossing fast towards another monitor: in and out in a few milliseconds.
    var crossing = DeckIntent(delay: 0.150)
    crossing.enter(at: point(1428), time: 20)
    crossing.move(to: point(1436), time: 20.008)   // 1000 pt/s
    expectTrue("intent: a fast crossing does not open",
               crossing.decision(now: 20.008) != .open)
    crossing.exit()
    expect("intent: and once it has left, nothing is pending", "\(crossing.decision(now: 20.2))", "\(DeckIntent.Decision.idle)")

    // Arriving slowly.
    var slow = DeckIntent(delay: 0.150)
    slow.enter(at: point(1430), time: 30)
    slow.move(to: point(1432), time: 30.016)       // 125 pt/s
    expect("intent: a slow arrival opens at once", "\(slow.decision(now: 30.016))", "\(DeckIntent.Decision.open)")

    // Just above the slow speed is a crossing.
    var brisk = DeckIntent(delay: 0.150)
    brisk.enter(at: point(1430), time: 40)
    brisk.move(to: point(1430 + DeckIntent.slowSpeed * 0.02, 400), time: 40.01)
    expectTrue("intent: faster than the slow speed waits", brisk.decision(now: 40.01) != .open)

    // A vertical slide along the stripe counts too.
    var vertical = DeckIntent(delay: 0.150)
    vertical.enter(at: point(1435, 400), time: 50)
    vertical.move(to: point(1435, 420), time: 50.01)  // 2000 pt/s
    expectTrue("intent: speed counts both directions", vertical.decision(now: 50.01) != .open)

    // A second visit starts the clock again.
    var again = DeckIntent(delay: 0.150)
    again.enter(at: point(1430), time: 60)
    again.exit()
    again.enter(at: point(1430), time: 61)
    expect("intent: a new visit waits its own delay",
           "\(again.decision(now: 61.1))", "\(DeckIntent.Decision.wait(until: 61.15))")
    again.move(to: point(1431), time: 61.1)
    expect("intent: a slow move on the new visit opens", "\(again.decision(now: 61.1))", "\(DeckIntent.Decision.open)")

    // Moves without an entry, or with no time between them, change nothing.
    var stray = DeckIntent(delay: 0.150)
    stray.move(to: point(1430), time: 70)
    expect("intent: a move without an entry is ignored", "\(stray.decision(now: 70))", "\(DeckIntent.Decision.idle)")
    stray.enter(at: point(1430), time: 71)
    stray.move(to: point(1431), time: 71)
    expectTrue("intent: no elapsed time is no speed", stray.decision(now: 71) != .open)

    // The setting.
    var instant = DeckIntent(delay: 0)
    instant.enter(at: point(1430), time: 80)
    expect("intent: zero delay opens on arrival", "\(instant.decision(now: 80))", "\(DeckIntent.Decision.open)")
    expect("intent: the default is 150 ms", String(Int(DeckIntent.defaultDelay * 1000)), "150")
    expect("intent: the delay is held to 400 ms", String(Int(DeckIntent(delay: 2).delay * 1000)), "400")
    expect("intent: and never below zero", String(Int(DeckIntent(delay: -1).delay * 1000)), "0")
    var longest = DeckIntent(delay: 0.4)
    longest.enter(at: point(1430), time: 90)
    expectTrue("intent: 400 ms has not passed at 399", longest.decision(now: 90.399) != .open)
    expect("intent: and has at 400", "\(longest.decision(now: 90.4))", "\(DeckIntent.Decision.open)")
}
