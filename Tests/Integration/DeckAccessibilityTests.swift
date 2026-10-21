import AppKit
import CryptoKit

/// The deck as VoiceOver reads it: the stripe a button, then once open every
/// tab a labelled button in the order it is drawn, then "+N", "+" and Today's Daily.
@MainActor
func runDeckAccessibilityTests() {
    let url = scratchDirectory().appendingPathComponent("deck-ax-\(UUID().uuidString).sqlite")
    let store = try! NoteStore(databaseURL: url, cipher: BodyCipher(key: SymmetricKey(size: .bits256)))
    let notes = try! store.create((0..<5).map { NoteDraft(title: "Note \($0)", tags: $0 == 1 ? ["daily"] : []) })
    let screen = NSScreen.main ?? NSScreen.screens[0]
    let controller = EdgePanelController(screen: screen)
    controller.update(notes: store.notes.filter { notes.map(\.id).contains($0.id) })
    let stack = controller.stackViewForTesting
    expectTrue("deck: resting, the stripe is a button", stack.isAccessibilityElement() && stack.accessibilityRole() == .button)
    expect("deck: named", stack.accessibilityLabel(), "KeepNote deck")
    expect("deck: and how many", stack.accessibilityValue() as? String, "5 notes")
    expectTrue("deck: pressing it opens the deck", stack.accessibilityPerformPress() && controller.isFanned)
    spin(0.3)
    let order = stack.accessibilityOrderForTesting
    let tabs = order.compactMap { $0 as? NoteCardView }
    expect("deck: every tab", String(tabs.count), "5")
    let drawn = tabs.sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
    expect("deck: in the order they are drawn, top to bottom", tabs.map { $0.accessibilityLabel() ?? "" }.joined(separator: ","),
           drawn.map { $0.accessibilityLabel() ?? "" }.joined(separator: ","))
    expectTrue("deck: tabs are buttons", tabs.allSatisfy { $0.isAccessibilityElement() && $0.accessibilityRole() == .button })
    expectTrue("deck: a daily says so", (tabs.first { $0.accessibilityLabel() == "Note 1" }?.accessibilityValue() as? String)?.contains("daily") == true)
    let rest = order.filter { !($0 is NoteCardView) }.map { $0.accessibilityLabel() ?? "" }
    expect("deck: then the buttons", rest.joined(separator: ","), "New Note,Today\u{2019}s Daily")
    controller.collapse()
    controller.hidePanel()
}

/// No state told by colour alone: a kept, a pinned and a floating tab say so.
@MainActor
func runTabStateWordsTests() {
    let url = scratchDirectory().appendingPathComponent("tab-words-\(UUID().uuidString).sqlite")
    let store = try! NoteStore(databaseURL: url, cipher: BodyCipher(key: SymmetricKey(size: .bits256)))
    var kept = try! store.create(title: "Kept", body: "")
    kept.keepOnDeck = true
    var pinned = try! store.create(color: .sky, title: "Pinned", body: "")
    pinned.pinnedAt = Date()
    let keptCard = NoteCardView(note: kept, height: EdgeMetrics.tabHeight)
    expect("words: kept", keptCard.accessibilityValue() as? String, "\(kept.color.displayName) note, kept on deck")
    let pinnedCard = NoteCardView(note: pinned, height: EdgeMetrics.tabHeight)
    expectTrue("words: pinned", (pinnedCard.accessibilityValue() as? String)?.hasPrefix("Sky note, pinned to center") == true)
    pinnedCard.isFloating = true
    expectTrue("words: floating", (pinnedCard.accessibilityValue() as? String)?.contains("floating") == true)
}
