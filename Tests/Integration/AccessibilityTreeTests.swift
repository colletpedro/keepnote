import AppKit
import CryptoKit
import SwiftUI

/// Walks what VoiceOver walks — the accessibility tree of the real windows —
/// and fails on any interactive element with no role or no name.
@MainActor
func runAccessibilityTreeTests() {
    // SwiftUI builds the accessibility nodes of its own views (Button, Label,
    // Text…) only while an assistive app is connected, which a test process
    // cannot ask for without Accessibility permission. Those are checked from
    // the source instead (Tests/AccessibilitySourceTests.swift); here the
    // tree holds AppKit's views, the system controls SwiftUI draws with, and
    // KeepNote's own elements (the deck, the note's text, its checkboxes).
    let url = scratchDirectory().appendingPathComponent("ax-tree-\(UUID().uuidString).sqlite")
    let store = try! NoteStore(databaseURL: url, cipher: BodyCipher(key: SymmetricKey(size: .bits256)))
    let notes = try! store.create([
        NoteDraft(title: "Weekly plan", body: "# Plan\n- [ ] Send the invoice\n- [x] Book the room\nSee [the doc](https://example.com)", tags: ["work"]),
        NoteDraft(title: "Daily", body: "- [ ] Standup", tags: ["daily"]),
        NoteDraft(title: "Ideas", body: "Plain text"),
    ])

    let interactive: Set<NSAccessibility.Role> = [.button, .checkBox, .radioButton, .popUpButton, .menuButton, .textField,
                                                 .textArea, .slider, .incrementor, .link, .comboBox, .disclosureTriangle]
    /// AppKit views and elements answer the modern methods (the classic
    /// attributes do not reach their overrides); anything else, the classic API.
    struct Node {
        var role: NSAccessibility.Role?
        var isElement: Bool
        var names: [String?]
        var children: [Any]
    }
    func read(_ object: NSObject) -> Node {
        if let view = object as? NSView {
            return Node(role: view.accessibilityRole(), isElement: view.isAccessibilityElement(),
                        names: [view.accessibilityLabel(), view.accessibilityTitle(), view.accessibilityPlaceholderValue(),
                                view.accessibilityValue() as? String, view.accessibilityHelp()],
                        children: view.accessibilityChildren().flatMap { $0.isEmpty ? nil : $0 }
                            ?? (view.accessibilityAttributeValue(.children) as? [Any]) ?? view.subviews.filter { !($0 is NSControl) })
        }
        if let element = object as? NSAccessibilityElement {
            return Node(role: element.accessibilityRole(), isElement: element.isAccessibilityElement(),
                        names: [element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityPlaceholderValue(),
                                element.accessibilityValue() as? String, element.accessibilityHelp()],
                        children: element.accessibilityChildren() ?? [])
        }
        let attribute = { (name: NSAccessibility.Attribute) in object.accessibilityAttributeValue(name) }
        return Node(role: (attribute(.role) as? String).map(NSAccessibility.Role.init(rawValue:)),
                    isElement: !object.accessibilityIsIgnored(),
                    names: [attribute(.description), attribute(.title), attribute(.placeholderValue), attribute(.value), attribute(.help)]
                        .map { $0 as? String },
                    children: attribute(.children) as? [Any] ?? [])
    }
    func name(_ node: Node) -> String {
        node.names.compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    }
    /// The pieces inside the system's own controls: a scroller's arrows, a
    /// stepper's halves, and the AppKit cells SwiftUI draws a Toggle, Picker,
    /// Slider or Stepper with, whose name SwiftUI's node for the control carries.
    let systemParts = ["NSAccessibilityScrollerPart", "NSAccessibilityStepperArrowButton", "EditTrackingStepperCell",
                       "PlatformSwitch", "SwiftUIPopupButtonCell", "CustomMarkedSliderCell"]
    /// Every interactive element under `root`, counted, and the problems.
    func walk(_ root: Any, _ place: String) -> (count: Int, problems: [String]) {
        var count = 0
        var problems: [String] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ node: Any, depth: Int) {
            guard depth < 60, let object = node as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let info = read(object)
            // Parts of system controls, named by the control they belong to.
            if systemParts.contains(where: { String(describing: type(of: node)).hasPrefix($0) }) { return }
            if ProcessInfo.processInfo.environment["AX_DEBUG"] != nil {
                print(String(repeating: " ", count: depth), type(of: node), info.role?.rawValue ?? "-", name(info), info.isElement, info.children.count)
            }
            if info.isElement {
                if let role = info.role, interactive.contains(role) {
                    count += 1
                    // A text area is named by its window and its text; the rest by a label.
                    if role != .textArea, name(info).isEmpty {
                        problems.append("\(place): \(role.rawValue) with no name (\(type(of: node)))")
                    }
                } else if info.role == nil || info.role == .unknown {
                    problems.append("\(place): element with no role (\(type(of: node)))")
                }
            }
            for child in info.children { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return (count, problems)
    }
    /// SwiftUI builds its accessibility tree for a window on screen: the
    /// window goes far off every display and is ordered in for real (the
    /// runner swaps the usual ordering methods out), then out again.
    func check(_ name: String, _ root: Any, atLeast: Int) {
        let window = (root as? NSView)?.window
        if let window {
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.test_orderFrontRegardless()   // the original, swapped in by the runner
        }
        defer { window?.orderOut(nil) }
        spin(0.4)
        let result = walk(root, name)
        expectTrue("tree (\(name)): has its controls (\(result.count))", result.count >= atLeast)
        expect("tree (\(name)): every control named, every element with a role", result.problems.joined(separator: "\n"), "")
    }

    // The deck, open.
    let deck = EdgePanelController(screen: NSScreen.main ?? NSScreen.screens[0])
    deck.update(notes: store.notes)
    _ = deck.stackViewForTesting.accessibilityPerformPress()
    check("deck", deck.stackViewForTesting, atLeast: 5)
    deck.collapse()
    deck.hidePanel()

    // A note, anchored and floating.
    let note = NoteWindowController(note: store.note(id: notes[0].id)!, store: store, originFrame: nil, cascadeIndex: 0)
    note.window.layoutIfNeeded()
    check("note", note.window.contentView!, atLeast: 5)
    note.togglePresentation()
    check("floating note", note.window.contentView!, atLeast: 5)
    note.close()

    // The peek.
    let peek = NSHostingView(rootView: NotePreviewView(note: store.note(id: notes[0].id)!))
    peek.frame = NSRect(origin: .zero, size: EdgeMetrics.previewSize)
    let peekWindow = NSWindow(contentRect: peek.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    peekWindow.contentView = peek
    check("peek", peek, atLeast: 0)

    // All Notes.
    let actions = NoteListActions(open: { _ in }, newNote: {}, archive: { _ in }, unarchive: { _ in }, delete: { _ in }, export: { _ in })
    let allNotes = HostingWindowController(title: "All Notes", size: NSSize(width: 1080, height: 640), autosaveName: "ax-test",
                                           rootView: AllNotesView(store: store, actions: actions, initialSelection: [notes[0].id]))
    allNotes.window.layoutIfNeeded()
    check("All Notes", allNotes.window.contentView!, atLeast: 0)
    allNotes.close()

    // Settings, every tab.
    let settingsWindow = SettingsWindowController(
        settings: AppSettings.shared, sync: FolderSyncService(store: store),
        actions: SettingsActions(chooseSyncFolder: {}, forgetSyncFolder: {}, importNotes: {}, exportAll: {}, showWelcome: {}),
        store: store)
    for tab in SettingsTab.allCases {
        settingsWindow.select(tab)
        settingsWindow.window.layoutIfNeeded()
        check("Settings \(tab.title)", settingsWindow.window.contentView!, atLeast: 0)
    }
    settingsWindow.window.close()

    // Welcome.
    let welcome = HostingWindowController(title: "Welcome", size: NSSize(width: 440, height: 724), autosaveName: "ax-welcome",
                                          rootView: WelcomeView(onDone: {}))
    welcome.window.layoutIfNeeded()
    check("Welcome", welcome.window.contentView!, atLeast: 0)
    welcome.close()
}

/// Text on the paper at 4.5:1 at least, with and without Increase contrast.
@MainActor
func runContrastTests() {
    func luminance(_ color: NSColor) -> Double {
        let c = color.usingColorSpace(.sRGB)!
        func channel(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }
    func ratio(_ a: NSColor, on b: NSColor) -> Double {
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
    defer { DisplayOptions.increaseContrastOverride = nil }
    for contrast in [false, true] {
        DisplayOptions.increaseContrastOverride = contrast
        let mode = contrast ? "Increase contrast" : "standard"
        for color in NoteColor.allCases {
            for (what, ink) in [("text", color.ink), ("quiet text", color.secondaryInk), ("links and marks", color.accent)] {
                let value = ratio(ink, on: color.surface)
                expectTrue("contrast (\(mode)): \(what) on \(color.displayName) paper is \(String(format: "%.2f", value)):1", value >= 4.5)
            }
            // The text on the tag chips and the spine sits on the spine colour.
            let spine = ratio(color.ink, on: color.spine)
            expectTrue("contrast (\(mode)): text on the \(color.displayName) spine is \(String(format: "%.2f", spine)):1", spine >= 4.5)
        }
    }
}
