import SwiftUI

/// One line of the suggestion list.
enum TagRow: Equatable {
    /// An existing tag, with how many notes carry it.
    case existing(tag: String, count: Int)
    /// A tag that does not exist yet: the word as typed, ready to keep.
    case create(tag: String)

    var tag: String {
        switch self {
        case .existing(let tag, _), .create(let tag): return tag
        }
    }
}

/// The suggestions for the tag being typed, drawn over the note just above the
/// tags field. It lives inside the note's own view, so it can neither take key
/// focus from the field nor be mistaken for a click outside the note.
struct TagSuggestionList: View {
    static let rowHeight: CGFloat = 24

    var rows: [TagRow]
    var selection: Int?
    var color: NoteColor
    var onAccept: (Int) -> Void
    var onHover: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                line(row, selected: index == selection)
                    .contentShape(Rectangle())
                    .onTapGesture { onAccept(index) }
                    .onHover { inside in if inside { onHover(index) } }
            }
        }
        .padding(4)
        .frame(width: 210)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.surfaceSwiftUI)
                .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(color.inkSwiftUI.opacity(0.16), lineWidth: 1)
        )
    }

    private func line(_ row: TagRow, selected: Bool) -> some View {
        HStack(spacing: 6) {
            switch row {
            case .existing(let tag, let count):
                Text("#\(tag)")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(color.inkSwiftUI.opacity(selected ? 0.7 : 0.4))
            case .create(let tag):
                Image(systemName: "plus")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(color.inkSwiftUI.opacity(0.55))
                Text("Create \"#\(tag)\"")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(color.inkSwiftUI.opacity(0.85))
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(color.spineSwiftUI.opacity(selected ? 0.38 : 0))
        )
    }
}
