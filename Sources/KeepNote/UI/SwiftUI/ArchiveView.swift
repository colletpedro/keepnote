import SwiftUI

/// The archive window: everything taken out of the stack but kept.
///
/// Archived notes keep their colour, their dates and their place in search —
/// the only thing archiving removes is the card on the edge.
struct ArchiveView: View {
    @ObservedObject var store: NoteStore
    var actions: NoteListActions

    @State private var query = ""
    @State private var selection: Set<UUID> = []

    private var results: [Note] {
        store.search(query, scope: .archived)
            .sorted { $0.editedAt > $1.editedAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if results.isEmpty {
                emptyState
            } else {
                List(selection: $selection) {
                    ForEach(results) { note in
                        ArchiveRow(note: note) {
                            actions.unarchive([note.id])
                        } onOpen: {
                            actions.open(note.id)
                        }
                        .tag(note.id)
                        .contextMenu {
                            Button("Open") { actions.open(note.id) }
                            Button("Move to Stack") { actions.unarchive([note.id]) }
                            Button("Export\u{2026}") { actions.export([note.id]) }
                            Divider()
                            Button("Delete", role: .destructive) { actions.delete([note.id]) }
                        }
                    }
                }
                .listStyle(.inset)
            }

            footer
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "archivebox")
                .foregroundStyle(.secondary)
            TextField("Search the archive", text: $query)
                .textFieldStyle(.roundedBorder)
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "archivebox")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(query.isEmpty ? "Nothing archived yet" : "No archived note matches that")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("\(results.count) archived")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Move to Stack") { actions.unarchive(Array(selection)) }
                .disabled(selection.isEmpty)
            Button("Export\u{2026}") { actions.export(Array(selection)) }
                .disabled(selection.isEmpty)
            Button("Delete", role: .destructive) {
                actions.delete(Array(selection))
                selection.removeAll()
            }
            .disabled(selection.isEmpty)
        }
        .padding(12)
    }
}

private struct ArchiveRow: View {
    let note: Note
    var onRestore: () -> Void
    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(note.color.spineSwiftUI.opacity(0.7))
                .frame(width: 3, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(note.displayTitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(note.preview)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let line = DeckStatus.archivedLine(for: note) {
                    Text(line)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text(Self.formatter.string(from: note.editedAt))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Button(action: onOpen) { Image(systemName: "doc.text") }
                .buttonStyle(.borderless)
                .help("Open")
            Button(action: onRestore) { Image(systemName: "tray.and.arrow.up") }
                .buttonStyle(.borderless)
                .help("Move back to the stack")
        }
        .padding(.vertical, 3)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()
}
