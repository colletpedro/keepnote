import AppKit
import CryptoKit

/// Clicking notes in a row, the way a hand does: A, then B before A has
/// settled, then A again — on the deck, which is where the bug was seen.
@MainActor
func runOpenRaceTests() {
    let key = SymmetricKey(size: .bits256)
    let store = reopened(scratchDirectory().appendingPathComponent("open-race.sqlite"), key: key)
    let notes = (0..<6).map { try! store.create(title: "race \($0)", body: "text \($0)") }
    let coordinator = AppCoordinator(store: store)

    func state(_ id: UUID) -> String {
        guard let w = coordinator.noteWindowForTesting(id) else { return "none" }
        return "reg closing=\(w.isClosingForChecks) vis=\(w.window.isVisible) alpha=\(w.window.alphaValue) mouse=\(!w.window.ignoresMouseEvents)"
    }
    func works(_ id: UUID) -> Bool {
        guard let w = coordinator.noteWindowForTesting(id) else { return false }
        return !w.isClosingForChecks && w.window.alphaValue == 1 && !w.window.ignoresMouseEvents
    }
    for reduce in [true, false] {
        Motion.reduceMotionOverride = reduce
        let fixture = DeckFixture(notes: store.activeNotes)
        fixture.controller.delegate = coordinator
        let ids = fixture.cards.map(\.noteID)
        func click(_ index: Int, wiggle: CGFloat = 0) {
            let card = fixture.cards[index]
            let p = fixture.pointOnSlice(index)
            card.mouseDown(with: fixture.event(.leftMouseDown, at: p))
            if wiggle > 0 { card.mouseDragged(with: fixture.event(.leftMouseDragged, at: NSPoint(x: p.x + wiggle, y: p.y))) }
            card.mouseUp(with: fixture.event(.leftMouseUp, at: p))
        }
        // A; B a beat later, which takes the keyboard from A (A is put away);
        // A again while it is still folding; then everything settles.
        click(0)
        spin(0.5)
        click(1)
        coordinator.noteWindowForTesting(ids[0])?.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        click(0)
        spin(0.8)
        expectTrue("race(\(reduce)): A, clicked again while it was folding away, is a note that works", works(ids[0]))
        expectTrue("race(\(reduce)): and B is still one", works(ids[1]))
        for id in ids { coordinator.noteWindowForTesting(id)?.close() }
        spin(0.7)
        fixture.close()
    }
    Motion.reduceMotionOverride = nil
}
