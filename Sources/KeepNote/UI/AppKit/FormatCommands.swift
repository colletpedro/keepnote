import AppKit

/// The formatting commands of the note editor, in one place: the Format menu,
/// the Tools menu, the top of the text's right-click menu and the shortcut
/// list all read this table, so they cannot drift apart. Each command is an
/// action on `MarkdownTextView`, whose implementation is the pure functions in
/// `Formatting` and `BlockEditing`.
enum FormatCommand: CaseIterable {
    // Text
    case bold, italic, strikethrough, highlight, inlineCode, link
    // Blocks
    case heading1, heading2, heading3
    case bulletList, numberedList, checklist, quote, codeBlock
    // Insert
    case table, divider, date

    enum Group: CaseIterable { case text, blocks, insert }

    var group: Group {
        switch self {
        case .bold, .italic, .strikethrough, .highlight, .inlineCode, .link: return .text
        case .heading1, .heading2, .heading3, .bulletList, .numberedList, .checklist, .quote, .codeBlock: return .blocks
        case .table, .divider, .date: return .insert
        }
    }

    var title: String {
        switch self {
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .strikethrough: return "Strikethrough"
        case .highlight: return "Highlight"
        case .inlineCode: return "Inline code"
        case .link: return "Link"
        case .heading1: return "Heading 1"
        case .heading2: return "Heading 2"
        case .heading3: return "Heading 3"
        case .bulletList: return "Bulleted list"
        case .numberedList: return "Numbered list"
        case .checklist: return "Checklist"
        case .quote: return "Quote"
        case .codeBlock: return "Code block"
        case .table: return "Table"
        case .divider: return "Divider"
        case .date: return "Today's date"
        }
    }

    /// The title inside the Heading submenu, where "Heading" is already said.
    var menuTitle: String {
        switch self {
        case .heading1: return "H1"
        case .heading2: return "H2"
        case .heading3: return "H3"
        default: return title
        }
    }

    var symbol: String {
        switch self {
        case .bold: return "bold"
        case .italic: return "italic"
        case .strikethrough: return "strikethrough"
        case .highlight: return "highlighter"
        case .inlineCode: return "chevron.left.forwardslash.chevron.right"
        case .link: return "link"
        case .heading1, .heading2, .heading3: return "textformat.size"
        case .bulletList: return "list.bullet"
        case .numberedList: return "list.number"
        case .checklist: return "checklist"
        case .quote: return "text.quote"
        case .codeBlock: return "curlybraces"
        case .table: return "tablecells"
        case .divider: return "minus"
        case .date: return "calendar"
        }
    }

    static let headings: [FormatCommand] = [.heading1, .heading2, .heading3]

    var action: Selector {
        switch self {
        case .bold: return #selector(MarkdownTextView.toggleBold(_:))
        case .italic: return #selector(MarkdownTextView.toggleItalic(_:))
        case .strikethrough: return #selector(MarkdownTextView.toggleStrikethrough(_:))
        case .highlight: return #selector(MarkdownTextView.toggleHighlight(_:))
        case .inlineCode: return #selector(MarkdownTextView.toggleInlineCode(_:))
        case .link: return #selector(MarkdownTextView.addLink(_:))
        case .heading1: return #selector(MarkdownTextView.setHeading1(_:))
        case .heading2: return #selector(MarkdownTextView.setHeading2(_:))
        case .heading3: return #selector(MarkdownTextView.setHeading3(_:))
        case .bulletList: return #selector(MarkdownTextView.toggleBulletList(_:))
        case .numberedList: return #selector(MarkdownTextView.toggleNumberedList(_:))
        case .checklist: return #selector(MarkdownTextView.toggleChecklist(_:))
        case .quote: return #selector(MarkdownTextView.toggleQuote(_:))
        case .codeBlock: return #selector(MarkdownTextView.toggleCodeBlock(_:))
        case .table: return #selector(MarkdownTextView.insertTable(_:))
        case .divider: return #selector(MarkdownTextView.insertDivider(_:))
        case .date: return #selector(MarkdownTextView.insertDate(_:))
        }
    }

    var key: String {
        switch self {
        case .bold: return "b"
        case .italic: return "i"
        case .strikethrough: return "x"
        case .highlight: return "h"
        case .inlineCode: return "e"
        case .link: return "k"
        case .heading1: return "1"
        case .heading2: return "2"
        case .heading3: return "3"
        case .bulletList: return "7"
        case .numberedList: return "9"
        case .checklist: return "l"
        case .quote: return "b"
        case .codeBlock: return "k"
        case .table: return "t"
        case .divider: return "r"
        case .date: return "d"
        }
    }

    var modifiers: NSEvent.ModifierFlags {
        switch self {
        case .bold, .italic, .inlineCode, .link: return [.command]
        case .heading1, .heading2, .heading3, .codeBlock, .table, .divider: return [.command, .option]
        default: return [.command, .shift]
        }
    }

    /// The shortcut as written on a keycap: `⇧⌘X`.
    var shortcutLabel: String {
        (modifiers.contains(.option) ? "\u{2325}" : "")
            + (modifiers.contains(.shift) ? "\u{21E7}" : "")
            + "\u{2318}" + key.uppercased()
    }

    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: menuTitle, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.image = Self.icon(symbol)
        return item
    }

    private static func icon(_ symbol: String) -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    /// The three headings behind one "Heading" item.
    private static func headingItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Heading", action: nil, keyEquivalent: "")
        item.image = icon("textformat.size")
        let submenu = NSMenu(title: "Heading")
        for command in headings { submenu.addItem(command.menuItem()) }
        item.submenu = submenu
        return item
    }

    /// Items for a menu, in order, a separator between the groups.
    static func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for group in Group.allCases {
            if !items.isEmpty { items.append(.separator()) }
            for command in allCases where command.group == group {
                if headings.contains(command) {
                    if command == .heading1 { items.append(headingItem()) }
                } else {
                    items.append(command.menuItem())
                }
            }
        }
        return items
    }

    /// The menu behind the note's Tools button. Items are aimed at `target`.
    static func makeToolsMenu(target: AnyObject) -> NSMenu {
        let menu = NSMenu(title: "Tools")
        for item in menuItems() {
            aim(item, at: target)
            menu.addItem(item)
        }
        return menu
    }

    /// Sets the target on an item and on everything in its submenu.
    static func aim(_ item: NSMenuItem, at target: AnyObject) {
        item.target = target
        item.submenu?.items.forEach { aim($0, at: target) }
    }

    /// The Format menu of the main menu. Never drawn — the app has no menu bar
    /// — but AppKit still reads its key equivalents while a note has focus.
    static func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Format")
        for item in menuItems() { menu.addItem(item) }
        return menu
    }
}
