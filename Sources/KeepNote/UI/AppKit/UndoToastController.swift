import AppKit
import SwiftUI

/// The ten-second window between "delete" and gone.
///
/// A non-activating panel near the bottom of the screen: it never takes focus,
/// so the user can keep typing in whatever they were doing and still take the
/// delete back.
@MainActor
final class UndoToastController {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    /// A plain notice: the same toast without the Undo button.
    /// How wide the last toast was made, for the tests.
    private(set) var widthForTesting: CGFloat = 0

    func notice(_ message: String, duration: TimeInterval = 2.5) {
        show(message: message, duration: duration, onUndo: nil)
    }

    func show(message: String, duration: TimeInterval, onUndo: (() -> Void)?) {
        dismiss()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 46),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let hosting = NSHostingView(
            rootView: UndoToastView(
                message: message,
                duration: duration,
                onUndo: onUndo.map { undo in
                    { [weak self] in
                        undo()
                        self?.dismiss()
                    }
                },
                onDismiss: { [weak self] in
                    self?.dismiss()
                }
            )
        )
        panel.contentView = hosting
        // As wide as the message needs, so a longer one (or a longer
        // language) is not cut short: never under 300 pt, never past 560.
        let width = min(560, max(300, ceil(hosting.fittingSize.width)))
        panel.setContentSize(NSSize(width: width, height: 46))
        widthForTesting = width

        if let screen = NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: area.midX - width / 2,
                y: area.minY + 64
            ))
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }
}

private struct UndoToastView: View {
    let message: String
    let duration: TimeInterval
    var onUndo: (() -> Void)?
    var onDismiss: () -> Void

    @State private var progress: Double = 1

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(.secondary.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 16, height: 16)

            Text(message)
                .font(.system(size: 12))
                .lineLimit(1)

            Spacer(minLength: 4)

            if let onUndo {
                Button(L("Undo"), action: onUndo)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.black.opacity(0.1), lineWidth: 1)
                )
        )
        .onAppear {
            withAnimation(.linear(duration: duration)) { progress = 0 }
        }
    }
}
