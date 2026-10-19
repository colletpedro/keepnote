import AppKit
import SwiftUI

/// The field in Settings > Shortcuts that records a shortcut.
///
/// Click it (or press Space on it) and press the combination: it is kept if
/// `onRecord` accepts it. Esc cancels, Delete leaves the action without a
/// shortcut. While it records, the global shortcuts are taken away and the
/// app's own keys (⌘Q, ⌘,) are not acted on, so the combination pressed comes
/// here instead of doing what it usually does.
final class ShortcutRecorderField: NSView {
    /// What became of a recording: kept, or refused for the reason given.
    enum Outcome: Equatable {
        case accepted
        case refused(String)
    }

    /// Any field recording right now. The app's key handlers stand aside.
    @MainActor static private(set) var isRecordingAny = false

    var actionTitle = ""
    var combo: KeyCombo? {
        didSet { if !isRecording { showCurrent() } }
    }
    /// Asked about every combination pressed, and about `nil` (Delete).
    var onRecord: ((KeyCombo?) -> Outcome)?
    var onRecordingChanged: ((Bool) -> Void)?

    private(set) var isRecording = false
    private let label = NSTextField(labelWithString: "")
    private var message: String?
    private var messageTask: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        showCurrent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 22) }
    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }

    // MARK: - Recording

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording ? stopRecording() : startRecording()
    }

    @MainActor func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        Self.isRecordingAny = true
        clearMessage()
        onRecordingChanged?(true)
        label.stringValue = L("Type a shortcut")
        updateLook()
        announce(L("Press the new shortcut for %@. Escape cancels, Delete leaves it without one.", actionTitle))
    }

    @MainActor func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        Self.isRecordingAny = false
        onRecordingChanged?(false)
        showCurrent()
        announce(L("%@ unchanged: %@", actionTitle, spokenCurrent))
    }

    override func resignFirstResponder() -> Bool {
        MainActor.assumeIsolated { stopRecording() }
        return super.resignFirstResponder()
    }

    /// ⌘-combinations reach a view as key equivalents, before `keyDown`.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        MainActor.assumeIsolated { record(event) }
        return true
    }

    override func keyDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard isRecording else {
                // Space or Return on the focused field starts recording.
                if [49, 36, 76].contains(event.keyCode) { startRecording() } else { super.keyDown(with: event) }
                return
            }
            record(event)
        }
    }

    /// While recording, the modifiers held so far, as a hint.
    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        let held = KeyCombo(keyCode: 0, carbonModifiers: KeyCombo.carbonFlags(from: event.modifierFlags))
        let glyphs = String(held.displayString.dropLast())   // without the key's name
        label.stringValue = glyphs.isEmpty ? L("Type a shortcut") : glyphs
    }

    @MainActor private func record(_ event: NSEvent) {
        let pressed = KeyCombo(event: event)
        let bare = pressed.carbonModifiers == 0
        if bare, event.keyCode == 53 {                       // Esc: keep what it was
            stopRecording()
            return
        }
        if bare, event.keyCode == 51 || event.keyCode == 117 {   // Delete: no shortcut
            finish(with: nil)
            return
        }
        finish(with: pressed)
    }

    @MainActor private func finish(with combo: KeyCombo?) {
        let outcome = onRecord?(combo) ?? .accepted
        isRecording = false
        Self.isRecordingAny = false
        onRecordingChanged?(false)
        switch outcome {
        case .accepted:
            self.combo = combo
            showCurrent()
            announce(combo == nil ? L("%@ now has no shortcut", actionTitle) : L("%@ set to %@", actionTitle, spokenCurrent))
        case .refused(let reason):
            show(reason)
            announce(L("%@. %@ keeps %@", reason, actionTitle, spokenCurrent))
        }
    }

    // MARK: - VoiceOver

    /// The shortcut as it would be read: "Option Command N", or "None".
    private var spokenCurrent: String { combo?.spokenString ?? L("None") }

    override func accessibilityLabel() -> String? { L("Shortcut for %@", actionTitle) }

    override func accessibilityValue() -> Any? {
        if isRecording { return L("Recording") }
        return message ?? spokenCurrent
    }

    override func accessibilityHelp() -> String? { L("Press to record a new shortcut.") }

    override func accessibilityPerformPress() -> Bool {
        MainActor.assumeIsolated {
            window?.makeFirstResponder(self)
            startRecording()
        }
        return true
    }

    /// What VoiceOver was last asked to say, for the tests.
    @MainActor static private(set) var lastAnnouncement: String?

    @MainActor private func announce(_ text: String) {
        Self.lastAnnouncement = text
        NSAccessibility.post(
            element: window ?? self,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    /// Drives the field as a press of `event` would, for the tests.
    @MainActor func recordForTesting(_ event: NSEvent) {
        if !isRecording { startRecording() }
        record(event)
    }

    // MARK: - Showing

    private func showCurrent() {
        guard message == nil else { return }
        label.stringValue = combo?.displayString ?? L("None")
        updateLook()
    }

    /// Why a combination was refused, for a moment; then the shortcut it kept.
    private func show(_ reason: String) {
        messageTask?.cancel()
        message = reason
        label.stringValue = reason
        updateLook()
        let task = DispatchWorkItem { [weak self] in self?.clearMessage() }
        messageTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: task)
    }

    private func clearMessage() {
        messageTask?.cancel()
        messageTask = nil
        message = nil
        showCurrent()
    }

    var messageForTesting: String? { message }
    var textForTesting: String { label.stringValue }

    private func updateLook() {
        let accent = NSColor.controlAccentColor
        layer?.borderColor = (isRecording ? accent : NSColor.separatorColor).cgColor
        layer?.backgroundColor = (isRecording ? accent.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).cgColor
        label.textColor = message != nil ? .systemRed : (combo == nil && !isRecording ? .secondaryLabelColor : .labelColor)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLook()
    }
}

/// The recorder in SwiftUI, for one action, kept in step with the store.
struct ShortcutRecorder: NSViewRepresentable {
    let action: ShortcutAction
    @ObservedObject var store: ShortcutStore
    var record: (KeyCombo?) -> ShortcutRecorderField.Outcome
    var recordingChanged: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> ShortcutRecorderField {
        let field = ShortcutRecorderField(frame: NSRect(x: 0, y: 0, width: 150, height: 22))
        update(field)
        return field
    }

    func updateNSView(_ field: ShortcutRecorderField, context: Context) {
        update(field)
    }

    private func update(_ field: ShortcutRecorderField) {
        field.actionTitle = action.title
        field.combo = store.combo(for: action)
        field.onRecord = record
        field.onRecordingChanged = recordingChanged
    }
}
