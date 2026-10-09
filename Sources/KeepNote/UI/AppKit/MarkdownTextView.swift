import AppKit

/// The note body's text view. It paints what `MarkdownStyler` can only mark —
/// bullets, checkboxes, quote bars, rules, code fills and tables sit where the
/// hidden markdown characters are — and keeps editing feeling like the text is
/// what it looks like: the caret skips hidden list markers, Backspace removes
/// one whole, Return continues a list, and clicking a checkbox flips the `[ ]`.
final class MarkdownTextView: NSTextView {
    /// Set by the coordinator whenever the note's colour changes.
    var accentColor: NSColor = .controlAccentColor
    var inkColor: NSColor = .labelColor
    /// Tables are laid out for a width, so a resize has to restyle.
    var onWidthChange: (() -> Void)?

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        let previous = frame.width
        super.setFrameSize(newSize)
        if abs(previous - newSize.width) > 0.5 {
            DispatchQueue.main.async { [weak self] in self?.onWidthChange?() }
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Drawn first, so the text lands on top; the view itself is transparent.
        drawDecorations(in: dirtyRect)
        super.draw(dirtyRect)
    }

    private func drawDecorations(in dirtyRect: NSRect) {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return }
        let origin = textContainerOrigin
        let visible = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

        storage.enumerateAttribute(MarkdownStyler.decorationKey, in: characters) { value, range, _ in
            guard let raw = value as? String, let kind = MarkdownStyler.Decoration(rawValue: raw) else { return }
            draw(kind, range: range)
        }
        storage.enumerateAttribute(MarkdownStyler.tableKey, in: characters) { value, _, _ in
            if let table = value as? TableLayout { draw(table) }
        }
    }

    private func draw(_ kind: MarkdownStyler.Decoration, range: NSRange) {
        switch kind {
        case .bullet:
            guard let frame = markerFrame(range, width: MarkdownStyler.bulletWidth) else { return }
            // • on the first level, ◦ on the second, ▪ on the third, by how far
            // the line is indented.
            let paragraph = (string as NSString).paragraphRange(for: range)
            let leading = (string as NSString).substring(with: NSRange(location: paragraph.location, length: range.location - paragraph.location))
            let bullet = NSRect(x: frame.minX + 3, y: frame.midY - 2.5, width: 5, height: 5)
            switch ListEditing.bulletKind(level: ListEditing.level(ofLeading: leading)) {
            case .disc:
                accentColor.setFill()
                NSBezierPath(ovalIn: bullet).fill()
            case .ring:
                accentColor.setStroke()
                let ring = NSBezierPath(ovalIn: bullet.insetBy(dx: 0.3, dy: 0.3))
                ring.lineWidth = 1.3
                ring.stroke()
            case .square:
                accentColor.setFill()
                NSBezierPath(rect: bullet.insetBy(dx: 0.25, dy: 0.25)).fill()
            }

        case .checkbox, .checkboxDone:
            guard let frame = markerFrame(range, width: MarkdownStyler.checkboxWidth) else { return }
            let box = NSRect(x: frame.minX + 1, y: frame.midY - 6.5, width: 13, height: 13)
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.7, dy: 0.7), xRadius: 3, yRadius: 3)
            if kind == .checkboxDone {
                accentColor.setFill()
                path.fill()
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: box.minX + 3.2, y: box.minY + 6.8))
                tick.line(to: NSPoint(x: box.minX + 5.6, y: box.minY + 9.2))
                tick.line(to: NSPoint(x: box.minX + 9.8, y: box.minY + 4.2))
                tick.lineWidth = 1.8
                tick.lineCapStyle = .round
                tick.lineJoinStyle = .round
                NSColor.white.setStroke()
                tick.stroke()
            } else {
                accentColor.withAlphaComponent(0.9).setStroke()
                path.lineWidth = 1.4
                path.stroke()
            }

        case .rule:
            guard let frame = markerFrame(range, width: 0),
                  let container = textContainer else { return }
            let padding = container.lineFragmentPadding
            let y = frame.midY.rounded() + 0.5
            let line = NSBezierPath()
            line.move(to: NSPoint(x: textContainerOrigin.x + padding, y: y))
            line.line(to: NSPoint(x: textContainerOrigin.x + container.size.width - padding, y: y))
            line.lineWidth = 1
            inkColor.withAlphaComponent(0.25).setStroke()
            line.stroke()

        case .quote:
            guard let bounds = paragraphBounds(containing: range), let container = textContainer else { return }
            accentColor.withAlphaComponent(0.7).setFill()
            let x = textContainerOrigin.x + container.lineFragmentPadding
            NSBezierPath(roundedRect: NSRect(x: x, y: bounds.minY, width: 3, height: bounds.height),
                         xRadius: 1.5, yRadius: 1.5).fill()

        case .codeLine:
            guard let layoutManager else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            inkColor.withAlphaComponent(0.07).setFill()
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y).fill()
            }
        }
    }

    private func draw(_ table: TableLayout) {
        guard let layoutManager, let container = textContainer else { return }
        let origin = textContainerOrigin
        let left = origin.x + container.lineFragmentPadding

        var rowFrames: [NSRect] = []
        for range in table.rowRanges {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return }
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            rowFrames.append(NSRect(x: left, y: origin.y + line.minY, width: table.totalWidth, height: line.height))
        }
        guard let first = rowFrames.first, let last = rowFrames.last else { return }
        let outer = NSRect(x: left, y: first.minY, width: table.totalWidth, height: last.maxY - first.minY)

        inkColor.withAlphaComponent(0.07).setFill()
        first.fill()

        let padX = TableLayout.cellPaddingX
        let padY = TableLayout.cellPaddingY
        for (rowIndex, frame) in rowFrames.enumerated() {
            var x = left
            for (column, width) in table.columnWidths.enumerated() {
                let cell = NSRect(x: x + padX, y: frame.minY + padY, width: width - padX * 2, height: frame.height - padY * 2)
                table.cells[rowIndex][column].draw(with: cell, options: [.usesLineFragmentOrigin])
                x += width
            }
        }

        let grid = NSBezierPath()
        grid.lineWidth = 1
        for frame in rowFrames.dropFirst() {
            grid.move(to: NSPoint(x: outer.minX, y: frame.minY.rounded() + 0.5))
            grid.line(to: NSPoint(x: outer.maxX, y: frame.minY.rounded() + 0.5))
        }
        var x = left
        for width in table.columnWidths.dropLast() {
            x += width
            grid.move(to: NSPoint(x: x.rounded() + 0.5, y: outer.minY))
            grid.line(to: NSPoint(x: x.rounded() + 0.5, y: outer.maxY))
        }
        inkColor.withAlphaComponent(0.22).setStroke()
        grid.stroke()

        let border = NSBezierPath(roundedRect: outer.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        border.lineWidth = 1
        border.stroke()
    }

    /// Where the first hidden character of a marker sits, in view coordinates.
    /// `width` is the room `MarkdownStyler` reserved after it.
    private func markerFrame(_ characters: NSRange, width: CGFloat) -> NSRect? {
        guard let layoutManager else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let location = layoutManager.location(forGlyphAt: glyphs.location)
        let origin = textContainerOrigin
        // Centre on the text itself, not on the line box: with a tall line the
        // extra leading sits above the glyphs, and the box's middle would float
        // above the text. `location.y` is the baseline within the fragment.
        let font = NSFont.systemFont(ofSize: MarkdownStyler.baseSize)
        let centre = origin.y + line.minY + location.y - font.capHeight / 2
        return NSRect(
            x: origin.x + line.minX + location.x,
            y: centre - used.height / 2,
            width: width,
            height: used.height
        )
    }

    /// The vertical extent of the paragraph a marker belongs to, wrapped lines
    /// included, so a quote's bar runs the whole way down.
    private func paragraphBounds(containing characters: NSRange) -> NSRect? {
        guard let layoutManager, let storage = textStorage else { return nil }
        let paragraph = (storage.string as NSString).paragraphRange(for: characters)
        let glyphs = layoutManager.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
        var union = NSRect.null
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
            union = union.union(used)
        }
        guard !union.isNull else { return nil }
        return union.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    // MARK: - Hidden list markers

    /// The bullet or checkbox run a character belongs to. Those are hidden
    /// characters standing in for a drawn shape, so they behave as one unit.
    private func hiddenMarker(at index: Int) -> NSRange? {
        guard let storage = textStorage, index >= 0, index < storage.length else { return nil }
        var run = NSRange()
        guard let raw = storage.attribute(MarkdownStyler.decorationKey, at: index, effectiveRange: &run) as? String,
              let kind = MarkdownStyler.Decoration(rawValue: raw),
              kind == .bullet || kind == .checkbox || kind == .checkboxDone else { return nil }
        return run
    }

    /// The caret never rests *inside* a hidden marker, where it would be
    /// invisible and cost keypresses to cross.
    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        var range = charRange
        if range.length == 0, let run = hiddenMarker(at: range.location), range.location > run.location {
            range.location = range.location < selectedRange().location ? run.location : NSMaxRange(run)
        }
        super.setSelectedRange(range, affinity: affinity, stillSelecting: stillSelectingFlag)
    }

    /// Backspace at the start of an item's text removes its marker, not one
    /// invisible character of it.
    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length == 0, let run = hiddenMarker(at: selection.location - 1),
           NSMaxRange(run) == selection.location {
            replace(run, with: "")
            setSelectedRange(NSRange(location: run.location, length: 0))
            renumber(around: NSRange(location: run.location, length: 0))
            return
        }
        super.deleteBackward(sender)
    }

    /// Return continues a list or quote; Return on an empty item ends it.
    override func insertNewline(_ sender: Any?) {
        if let result = ListEditing.newline(currentEdit) {
            apply(result)
        } else {
            super.insertNewline(sender)
        }
    }

    /// Tab and Shift-Tab move list items a level in or out; anywhere else Tab
    /// is what it always was.
    override func insertTab(_ sender: Any?) {
        if let result = ListEditing.indent(currentEdit, outdent: false) { apply(result) } else { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if let result = ListEditing.indent(currentEdit, outdent: true) { apply(result) } else { super.insertBacktab(sender) }
    }

    /// The text and selection, as the pure editing functions see them.
    var currentEdit: TextEdit {
        TextEdit(text: string, selection: selectedRange())
    }

    /// Applies the result of an editing function as one undoable change: only
    /// the part of the text that differs is replaced, then the selection is set.
    func apply(_ edit: TextEdit) {
        let change = currentEdit.minimalChange(to: edit)
        isApplyingEdit = true
        defer { isApplyingEdit = false }
        if change.range.length > 0 || !change.string.isEmpty {
            replace(change.range, with: change.string)
        }
        setSelectedRange(edit.selection)
    }

    // MARK: - Formatting

    @objc func toggleBold(_ sender: Any?) { apply(Formatting.toggle(currentEdit, .bold)) }
    @objc func toggleItalic(_ sender: Any?) { apply(Formatting.toggle(currentEdit, .italic)) }
    @objc func toggleStrikethrough(_ sender: Any?) { apply(Formatting.toggle(currentEdit, .strike)) }

    @objc func toggleHighlight(_ sender: Any?) { apply(Formatting.toggle(currentEdit, .highlight)) }
    @objc func toggleInlineCode(_ sender: Any?) { apply(Formatting.toggle(currentEdit, .code)) }
    @objc func setHeading1(_ sender: Any?) { apply(BlockEditing.heading(currentEdit, level: 1)) }
    @objc func setHeading2(_ sender: Any?) { apply(BlockEditing.heading(currentEdit, level: 2)) }
    @objc func setHeading3(_ sender: Any?) { apply(BlockEditing.heading(currentEdit, level: 3)) }
    @objc func toggleQuote(_ sender: Any?) { apply(BlockEditing.quote(currentEdit)) }
    @objc func toggleCodeBlock(_ sender: Any?) { apply(BlockEditing.codeBlock(currentEdit)) }
    @objc func insertTable(_ sender: Any?) { apply(BlockEditing.insertTable(currentEdit)) }
    @objc func insertDivider(_ sender: Any?) { apply(BlockEditing.insertDivider(currentEdit)) }
    @objc func insertDate(_ sender: Any?) { apply(BlockEditing.insertDate(currentEdit)) }

    @objc func toggleBulletList(_ sender: Any?) { apply(Formatting.toggleList(currentEdit, .bullet)) }
    @objc func toggleNumberedList(_ sender: Any?) { apply(Formatting.toggleList(currentEdit, .numbered)) }
    @objc func toggleChecklist(_ sender: Any?) { apply(Formatting.toggleList(currentEdit, .checklist)) }

    /// ⌘K. Uses the clipboard's URL when it holds one.
    @objc func addLink(_ sender: Any?) {
        let clipboard = NSPasteboard.general.string(forType: .string)
        if let result = Formatting.link(currentEdit, clipboard: clipboard) { apply(result) } else { NSSound.beep() }
    }

    /// A URL pasted over selected text becomes a link on that text.
    override func paste(_ sender: Any?) {
        if isEditable, let pasted = NSPasteboard.general.string(forType: .string),
           let result = Formatting.pasteURL(currentEdit, pasted: pasted) {
            apply(result)
        } else {
            super.paste(sender)
        }
    }

    /// The right-click menu: the Format commands on top, above the standard
    /// items, so what the shortcuts do is discoverable where the text is.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard let menu, isEditable else { return menu }
        if menu.items.first?.action != FormatCommand.bold.action {
            let items = FormatCommand.menuItems()
            for (offset, item) in items.enumerated() {
                FormatCommand.aim(item, at: self)
                menu.insertItem(item, at: offset)
            }
            menu.insertItem(.separator(), at: items.count)
        }
        return menu
    }

    /// The format commands are only live while the note can be edited.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if let action = item.action, FormatCommand.allCases.contains(where: { $0.action == action }) {
            return isEditable
        }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: - Numbering

    /// True while `apply` runs: the pure function already renumbered.
    private var isApplyingEdit = false
    /// Where the last edit that touched a line break landed, in the text as it
    /// is now.
    private var pendingRenumber: NSRange?

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let allowed = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        guard allowed, !isApplyingEdit, undoManager?.isUndoing != true, undoManager?.isRedoing != true else { return allowed }

        // Only edits that add or remove a line break can change what follows
        // them in a numbered list: pasting, cutting, joining or splitting lines.
        let replacement = (replacementString ?? "") as NSString
        let removed = (string as NSString).substring(with: affectedCharRange)
        if replacement.contains("\n") || removed.contains("\n") {
            pendingRenumber = NSRange(location: affectedCharRange.location, length: replacement.length)
        }
        return allowed
    }

    override func didChangeText() {
        super.didChangeText()
        guard let touched = pendingRenumber else { return }
        pendingRenumber = nil
        renumber(around: touched)
    }

    private func renumber(around touched: NSRange) {
        let length = (string as NSString).length
        let location = min(touched.location, length)
        let range = NSRange(location: location, length: min(touched.length, length - location))
        let current = currentEdit
        let result = ListEditing.renumber(current, touching: range)
        if result != current { apply(result) }
    }

    /// An edit through the normal path, so it is undoable and reaches the
    /// autosave like a keystroke.
    private func replace(_ range: NSRange, with string: String) {
        guard let storage = textStorage else { return }
        if shouldChangeText(in: range, replacementString: string) {
            storage.replaceCharacters(in: range, with: string)
            didChangeText()
        }
    }

    // MARK: - Clicks

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let box = checkbox(at: point) {
            toggleCheckbox(markerRange: box)
            return
        }
        if event.modifierFlags.contains(.command), let url = link(at: point) {
            NSWorkspace.shared.open(url)
            return
        }
        super.mouseDown(with: event)
    }

    private func checkbox(at point: NSPoint) -> NSRange? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        var hit: NSRange?
        storage.enumerateAttribute(MarkdownStyler.decorationKey, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard let raw = value as? String,
                  raw == MarkdownStyler.Decoration.checkbox.rawValue
                    || raw == MarkdownStyler.Decoration.checkboxDone.rawValue,
                  let frame = markerFrame(range, width: MarkdownStyler.checkboxWidth) else { return }
            if frame.insetBy(dx: -2, dy: -2).contains(point) {
                hit = range
                stop.pointee = true
            }
        }
        return hit
    }

    /// Flips the character between the brackets.
    private func toggleCheckbox(markerRange: NSRange) {
        guard let storage = textStorage else { return }
        let marker = (storage.string as NSString).substring(with: markerRange) as NSString
        let bracket = marker.range(of: "[")
        guard bracket.location != NSNotFound, bracket.location + 1 < marker.length else { return }

        let state = NSRange(location: markerRange.location + bracket.location + 1, length: 1)
        let current = (storage.string as NSString).substring(with: state)
        replace(state, with: current == " " ? "x" : " ")
    }

    private func link(at point: NSPoint) -> URL? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let index = characterIndexForInsertion(at: point)
        for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
            guard let raw = storage.attribute(MarkdownStyler.linkKey, at: candidate, effectiveRange: nil) as? String,
                  let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme) else { continue }
            return url
        }
        return nil
    }
}
