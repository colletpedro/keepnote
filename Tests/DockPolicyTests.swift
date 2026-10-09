import Foundation

func runDockPolicyTests() {
    func policy(_ kinds: Set<AppWindowKind>) -> String { "\(DockPolicy.policy(for: kinds))" }

    expect("nothing open: out of the Dock", policy([]), "accessory")
    expect("deck alone", policy([.deck]), "accessory")
    expect("deck, peek and notes do not count", policy([.deck, .peek, .anchoredNote, .detachedNote]), "accessory")
    for kind in [AppWindowKind.allNotes, .archive, .settings, .about, .welcome, .dailyTemplate] {
        expect("\(kind) alone puts it in the Dock", policy([kind]), "regular")
        expect("\(kind) beside the deck and a note", policy([kind, .deck, .detachedNote]), "regular")
    }
    expect("several standard windows", policy([.allNotes, .settings]), "regular")
    expect("standard kinds are exactly six",
           AppWindowKind.allCases.filter(\.isStandard).map { "\($0)" }.joined(separator: ","),
           "allNotes,archive,settings,about,welcome,dailyTemplate")

    func change(_ current: DockPolicy, _ kinds: Set<AppWindowKind>) -> String {
        DockPolicy.change(from: current, open: kinds).map { "\($0)" } ?? "nil"
    }
    expect("first standard window opens: switch to regular", change(.accessory, [.allNotes, .deck]), "regular")
    expect("a second one: no switch", change(.regular, [.allNotes, .settings]), "nil")
    expect("one of two closes: no switch", change(.regular, [.settings]), "nil")
    expect("the last closes: back to accessory", change(.regular, [.deck, .detachedNote]), "accessory")
    expect("a note opening while accessory: no switch", change(.accessory, [.anchoredNote]), "nil")
}
