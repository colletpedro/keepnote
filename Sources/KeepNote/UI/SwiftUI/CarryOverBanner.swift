import AppKit
import SwiftUI

/// The offer at the top of a new daily: how many tasks, from which day, and
/// the two answers. `answer` is called once, with `true` for Bring.
struct CarryOverBanner {
    var count: Int
    var weekday: String
    var answer: (Bool) -> Void

    var message: String {
        count == 1
            ? L("1 unfinished task from %@. Bring it?", weekday)
            : L("%d unfinished tasks from %@. Bring them?", count, weekday)
    }
}

/// A quiet strip inside the note, under its header. VoiceOver hears it as
/// soon as it shows; Bring and Not now are ordinary buttons, so Tab (with
/// keyboard navigation on) and VoiceOver both reach them.
struct CarryOverBannerView: View {
    let banner: CarryOverBanner
    let color: NoteColor
    var answer: (Bool) -> Void

    var body: some View {
        // On one line when it fits; in a narrow note, the answers under the
        // question rather than the question squeezed into a column.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                icon
                message.fixedSize()
                Spacer(minLength: 6)
                buttons
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    icon
                    message.fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    buttons
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(color.spineSwiftUI.opacity(0.35))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(banner.message)
        .onAppear {
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [.announcement: banner.message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
            )
        }
    }

    private var icon: some View {
        Image(systemName: "checklist")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color.secondaryInkSwiftUI)
            .accessibilityHidden(true)
    }

    private var message: some View {
        Text(banner.message)
            .font(.system(size: 12))
            .foregroundStyle(color.inkSwiftUI)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button(L("Not now")) { answer(false) }
                .buttonStyle(NoteFooterButtonStyle(color: color))
            // No Return shortcut: Return belongs to the text being typed.
            Button(L("Bring")) { answer(true) }
                .buttonStyle(NoteFooterButtonStyle(color: color))
        }
        .fixedSize()
    }
}
