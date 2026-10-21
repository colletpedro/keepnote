import Foundation

func runAccessibilityTextTests() {
    typealias State = AccessibilityText.TabState
    expect("tab: just its colour", AccessibilityText.tabDescription(State(colorName: "Butter")), "Butter note")
    expect("tab: every state, in order",
           AccessibilityText.tabDescription(State(colorName: "Sky", isPinned: true, isKept: true, isFloating: true, isDaily: true, daysLeft: 2)),
           "Sky note, pinned to center, kept on deck, floating, daily, archives in 2 days")
    expect("tab: archives tomorrow", AccessibilityText.tabDescription(State(colorName: "Mint", daysLeft: 1)), "Mint note, archives tomorrow")
    expect("deck: how many", AccessibilityText.deckValue(count: 8), "8 notes")
    expect("deck: one", AccessibilityText.deckValue(count: 1), "1 note")
    expect("chip: more", AccessibilityText.overflowLabel(count: 12), "12 more notes")
    // In Portuguese, from the table.
    expect("tab (pt): every state", String(format: L("%@ note", in: "pt-BR"), "Céu") + ", " + L("pinned to center", in: "pt-BR"),
           "Nota Céu, fixada no centro")
}
