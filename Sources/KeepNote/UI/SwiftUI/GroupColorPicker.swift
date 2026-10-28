import SwiftUI

/// The twelve colours of a group in a grid, the current one marked. Choosing
/// one applies it and is the caller's cue to close. Every swatch is a button
/// with its name, so the keyboard (Tab, Space) and VoiceOver reach them.
struct GroupColorGrid: View {
    let current: GroupColor
    let onChoose: (GroupColor) -> Void

    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 8), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(GroupColor.allCases, id: \.self) { color in
                Button { onChoose(color) } label: {
                    ZStack {
                        Circle().fill(color.fillSwiftUI)
                        Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 1)
                        if color == current {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(color.inkSwiftUI)
                        }
                    }
                    .frame(width: 28, height: 28)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(color.displayName)
                .accessibilityLabel(color.displayName)
                .accessibilityAddTraits(color == current ? .isSelected : [])
            }
        }
        .padding(14)
        .fixedSize()
    }
}

/// A group's colour dot as a button: next to its name in the sidebar. One
/// click opens the grid; choosing a colour applies it and closes. At least
/// 24 pt to hit.
struct GroupColorDotButton: View {
    let color: GroupColor
    let onChoose: (GroupColor) -> Void
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Image(nsImage: GroupMenu.swatch(color, size: 12))
                .frame(width: EdgeMetrics.groupColorButton, height: EdgeMetrics.groupColorButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(L("Group color: %@", color.displayName))
        .accessibilityLabel(L("Group color: %@", color.displayName))
        .popover(isPresented: $open, arrowEdge: .trailing) {
            GroupColorGrid(current: color) { chosen in
                onChoose(chosen)
                open = false
            }
        }
    }
}
