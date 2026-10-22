import AppKit

// MARK: - Hover magnification: Off to Large

@MainActor
func runHoverMagnificationTests() {
    // The setting: the deck's own 12 pt by default, clamped, and kept.
    let suiteName = "keepnote-magnification-\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: suiteName)!
    defer { suite.removePersistentDomain(forName: suiteName) }
    let fresh = AppSettings(defaults: suite)
    expect("setting: the default is level 2", String(fresh.hoverMagnification), "2")
    expect("setting: which is the 12 pt of today", String(Double(fresh.hoverLift)), String(Double(EdgeMetrics.hoverLift)))
    fresh.hoverMagnification = 99
    expect("setting: Large is the top of the slider", String(fresh.hoverMagnification), String(EdgeMetrics.hoverMagnificationLevels))
    fresh.hoverMagnification = -4
    expect("setting: Off is the bottom", String(fresh.hoverMagnification), "0")
    expect("setting: Off is no lift", String(Double(fresh.hoverLift)), "0.0")
    expect("setting: kept for the next launch", String(AppSettings(defaults: suite).hoverMagnification), "0")
    expect("setting: the words VoiceOver hears, Off", DeckSettingsPane.magnificationWords(0), "Off")
    expect("setting: and Large", DeckSettingsPane.magnificationWords(EdgeMetrics.hoverMagnificationLevels), "Large")
    expect("setting: and between, in points", DeckSettingsPane.magnificationWords(2), "12 pt")

    // The deck at every level: the tab under the cursor reaches out by the
    // lift, over its neighbours, and nothing else moves. Reduce Motion is on in
    // the fixture, so a tab is at its final size the moment the cursor is on it.
    let shared = AppSettings.shared
    let original = shared.hoverMagnification
    defer { shared.hoverMagnification = original }
    for level in [0, 2, EdgeMetrics.hoverMagnificationLevels] {
        shared.hoverMagnification = level
        let lift = EdgeMetrics.lift(forMagnification: level)
        let deck = DeckFixture(count: 30)
        deck.controller.applySettings()
        let cards = deck.cards
        let resting = cards.map(\.frame)
        expect("level \(level): the deck is as wide as the lift and its shadow need",
               String(Double(deck.stack.frame.width)), String(Double(EdgeMetrics.tabWidth + EdgeMetrics.gutter(forLift: lift))))

        deck.move(to: deck.pointOnSlice(14))
        expectTrue("level \(level): the tab under the cursor is hovered", deck.stack.hoveredNoteID == deck.notes[14].id)
        expect("level \(level): it reaches out by the lift", String(Double(cards[14].frame.width)), String(Double(EdgeMetrics.tabWidth + lift)))
        expectTrue("level \(level): from the same edge, in the same place",
                   cards[14].frame.maxX == resting[14].maxX && cards[14].frame.minY == resting[14].minY)
        expectTrue("level \(level): and no other tab moves",
                   cards.indices.filter { $0 != 14 }.allSatisfy { cards[$0].frame == resting[$0] })
        expectTrue("level \(level): it is over its neighbours", cards[14].superview?.subviews.last === cards[14])
        expectTrue("level \(level): and shows whole", cards[14].visibleSlice == EdgeMetrics.tabHeight)
        // The cursor in the part that has grown out is still on the tab.
        let outward = cards[14].superview!.convert(deck.pointOnSlice(14), from: nil)
        let reach = NSPoint(x: resting[14].minX - lift / 2, y: outward.y)
        let inWindow = cards[14].superview!.convert(reach, to: nil)
        if lift > 0 {
            deck.move(to: inWindow)
            expectTrue("level \(level): the grown part belongs to the tab", deck.stack.hoveredNoteID == deck.notes[14].id)
        }
        deck.stack.mouseExited(with: deck.event(.mouseMoved, at: .zero))
        expectTrue("level \(level): leaving puts it back", cards.map(\.frame) == resting)
        deck.close()
    }

    // Reduce Motion: no travel, only the final size; without it, the tab is on
    // its way (a spring), not there yet.
    shared.hoverMagnification = 6
    do {
        let deck = DeckFixture(count: 12)
        let before = deck.cards[5].frame.width
        deck.move(to: deck.pointOnSlice(5))
        expectTrue("motion: with Reduce Motion the size is the final one at once",
                   deck.cards[5].frame.width == before + EdgeMetrics.lift(forMagnification: 6))
        Motion.reduceMotionOverride = false
        deck.stack.mouseExited(with: deck.event(.mouseMoved, at: .zero))
        deck.move(to: deck.pointOnSlice(8))
        expectTrue("motion: without it the tab springs toward the size, and is aimed at it",
                   deck.cards[8].targetFrame.width == EdgeMetrics.tabWidth + EdgeMetrics.lift(forMagnification: 6)
                   && deck.cards[8].frame.width < EdgeMetrics.tabWidth + EdgeMetrics.lift(forMagnification: 6))
        Motion.reduceMotionOverride = true
        deck.close()
    }
    shared.hoverMagnification = original
}
