import SwiftUI

/// The note as it looks under the cursor, before any click.
///
/// The open note's own look, without its controls: the spine in the spine
/// colour with the perforation, then a header and the paper. The title is
/// written once, in the header, and the body underneath is `Note.preview` —
/// which already leaves out the first line when that line stood in for the
/// title — so nothing is said twice.
struct NotePreviewView: View {
    let note: Note

    var body: some View {
        HStack(spacing: 0) {
            spine
            content
        }
        .background(note.color.surfaceSwiftUI)
    }

    private var spine: some View {
        ZStack {
            note.color.spineSwiftUI
            HStack {
                Spacer()
                PerforationLine(color: note.color.inkSwiftUI.opacity(0.28))
                    .padding(.vertical, 10)
            }
        }
        .frame(width: EdgeMetrics.tabWidth)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(note.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(note.color.inkSwiftUI)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            Text(note.preview)
                .font(.system(size: 14))
                .foregroundStyle(note.body.isEmpty ? note.color.secondaryInkSwiftUI : note.color.inkSwiftUI)
                .lineSpacing(5.5)
                .lineLimit(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // A look does not count as opening, so the peek says how long the
            // note has left.
            if let line = DeckStatus.line(for: note) {
                Text(line)
                    .font(.system(size: 10.5))
                    .foregroundStyle(note.color.secondaryInkSwiftUI)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// The tear line between spine and body, as a dashed rule.
struct PerforationLine: View {
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: 0.5, y: 0))
                path.addLine(to: CGPoint(x: 0.5, y: proxy.size.height))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1, dash: [2.5, 3.5]))
        }
        .frame(width: 1)
    }
}

/// The vertical title on a tab.
///
/// A rotated `Text` is laid out at its pre-rotation width, so a long title
/// would stretch the strip it sits in. Here the label is given a fixed length
/// first — the strip's height minus the reserved top zone — truncated to it,
/// and only then rotated; the view itself takes whatever space it is offered
/// and contributes nothing to the strip's width.
struct SpineLabel: View {
    let text: String
    let color: Color
    /// Height reserved at the top (the close button, in the editor).
    var topInset: CGFloat = 0
    private let margin: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            let length = max(0, proxy.size.height - topInset - 2 * margin)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(color)
                .frame(width: length)
                .rotationEffect(.degrees(90))
                .position(x: proxy.size.width / 2, y: topInset + margin + length / 2)
        }
    }
}
