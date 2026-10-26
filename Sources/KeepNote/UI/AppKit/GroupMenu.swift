import AppKit

/// "Move to Group ›": the submenu every place a note can be moved from shares
/// — a tab's right click, a note's Tools, the All Notes pane.
@MainActor
enum GroupMenu {
    /// A group the menu offers.
    struct Choice: Equatable {
        var id: UUID
        var name: String
        var color: GroupColor
    }

    static func choices(_ groups: [NoteGroup]) -> [Choice] {
        groups.map { Choice(id: $0.id, name: $0.name, color: $0.color) }
    }

    /// What the items do. The menu does not own it: whoever pops the menu keeps
    /// it alive for as long as the menu is up.
    final class Target: NSObject {
        let onChoose: (UUID?) -> Void
        let onNewGroup: () -> Void

        init(choose: @escaping (UUID?) -> Void, newGroup: @escaping () -> Void) {
            onChoose = choose
            onNewGroup = newGroup
        }

        @objc func choose(_ item: NSMenuItem) { onChoose(item.representedObject as? UUID) }
        @objc func newGroup() { onNewGroup() }
    }

    /// The "Move to Group" item: No Group, each group (ticked where the note
    /// is), then New Group…. `enabled` is off for a note that cannot be moved
    /// (a daily belongs to Daily).
    static func makeItem(choices: [Choice], current: UUID?, enabled: Bool = true, target: Target) -> NSMenuItem {
        let item = NSMenuItem(title: L("Move to Group"), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        let menu = NSMenu(title: L("Move to Group"))
        menu.autoenablesItems = false

        let none = NSMenuItem(title: L("No Group"), action: #selector(Target.choose(_:)), keyEquivalent: "")
        none.target = target
        none.state = current == nil ? .on : .off
        menu.addItem(none)
        if !choices.isEmpty { menu.addItem(.separator()) }
        for choice in choices {
            let entry = NSMenuItem(title: choice.name, action: #selector(Target.choose(_:)), keyEquivalent: "")
            entry.target = target
            entry.representedObject = choice.id
            entry.state = current == choice.id ? .on : .off
            entry.image = swatch(choice.color)
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let new = NSMenuItem(title: L("New Group\u{2026}"), action: #selector(Target.newGroup), keyEquivalent: "")
        new.target = target
        menu.addItem(new)

        item.submenu = menu
        item.isEnabled = enabled
        return item
    }

    /// A small dot in a group's colour, for menus.
    static func swatch(_ color: GroupColor, size: CGFloat = 11) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.fill.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}
