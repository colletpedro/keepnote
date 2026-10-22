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
    /// Settings > General > Text size: the marks grow with the text.
    var textScale: CGFloat = 1
    /// The body's font, for lines whose first character is hidden.
    var bodyFont: NSFont = .systemFont(ofSize: MarkdownStyler.baseSize)
    /// The spine colour, for highlights and find matches.
    var highlightColor: NSColor = .systemYellow
    /// Find in note: every match, and which one is current.
    var findMatches: [NSRange] = [] { didSet { if findMatches != oldValue { needsDisplay = true } } }
    var currentFindMatch: Int? { didSet { if currentFindMatch != oldValue { needsDisplay = true } } }
    /// Tables are laid out for a width, so a resize has to restyle.
    var onWidthChange: (() -> Void)?
    /// The markup shows around the caret only while the text has the
    /// keyboard, so gaining or losing it restyles.
    var onFocusChange: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { DispatchQueue.main.async { [weak self] in self?.onFocusChange?() } }
        return resigned
    }

    /// Whether the text has the keyboard (its window's first responder).
    var hasKeyboardFocus: Bool { window?.firstResponder === self }
    /// Where the note's attachments are kept, for drawing and adding them.
    weak var library: NoteStore?
    /// Where ⌘V reads from: the clipboard (the tests hand in their own).
    var pasteSource: NSPasteboard = .general
    /// The file Quick Look is showing, while it is.
    var quickLookURL: URL?
    var quickLookHolding = false

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
        // A little past the dirty rectangle, so a mark whose line is only
        // partly redrawn is drawn whole rather than cut at the edge.
        let visible = dirtyRect.insetBy(dx: 0, dy: -12).offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

        storage.enumerateAttribute(MarkdownStyler.decorationKey, in: characters) { value, range, _ in
            guard let raw = value as? String, let kind = MarkdownStyler.Decoration(rawValue: raw) else { return }
            draw(kind, range: range)
        }
        storage.enumerateAttribute(MarkdownStyler.tableKey, in: characters) { value, _, _ in
            if let table = value as? TableLayout { draw(table) }
        }
        storage.enumerateAttribute(MarkdownStyler.inlineBoxKey, in: characters) { value, range, _ in
            guard let raw = value as? String, let kind = MarkdownStyler.InlineBox(rawValue: raw) else { return }
            let color = kind == .code ? inkColor.withAlphaComponent(0.09) : highlightColor.withAlphaComponent(0.42)
            color.setFill()
            for box in textBoxes(range) {
                NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
            }
        }
        drawFindMatches(in: characters)
        attachmentLayouts(in: characters).forEach(drawAttachment)
    }

    /// Where a list mark is drawn, in view coordinates: the bullet's dot or
    /// the checkbox, centred on the middle of the capitals of the line's
    /// text — which is also the middle of a numbered item's digits, so the
    /// three kinds line up with each other and with the words.
    func markRect(_ kind: MarkdownStyler.Decoration, range: NSRange) -> NSRect? {
        switch kind {
        case .bullet:
            guard let frame = markerFrame(range, width: MarkdownStyler.bulletWidth * textScale) else { return nil }
            let side = (5 * textScale).rounded(.toNearestOrEven)
            return NSRect(x: frame.minX + 3 * textScale, y: frame.midY - side / 2, width: side, height: side)
        case .checkbox, .checkboxDone:
            guard let frame = markerFrame(range, width: MarkdownStyler.checkboxWidth * textScale) else { return nil }
            let side = (13 * textScale).rounded()
            return NSRect(x: frame.minX + 1 * textScale, y: frame.midY - side / 2, width: side, height: side)
        default:
            return nil
        }
    }

    private func draw(_ kind: MarkdownStyler.Decoration, range: NSRange) {
        switch kind {
        case .bullet:
            guard let bullet = markRect(kind, range: range) else { return }
            // • on the first level, ◦ on the second, ▪ on the third, by how far
            // the line is indented.
            let paragraph = (string as NSString).paragraphRange(for: range)
            let leading = (string as NSString).substring(with: NSRange(location: paragraph.location, length: range.location - paragraph.location))
            switch ListEditing.bulletKind(level: ListEditing.level(ofLeading: leading)) {
            case .disc:
                accentColor.setFill()
                NSBezierPath(ovalIn: bullet).fill()
            case .ring:
                accentColor.setStroke()
                let ring = NSBezierPath(ovalIn: bullet.insetBy(dx: 0.65, dy: 0.65))
                ring.lineWidth = 1.3
                ring.stroke()
            case .square:
                accentColor.setFill()
                NSBezierPath(rect: bullet.insetBy(dx: 0.25, dy: 0.25)).fill()
            }

        case .checkbox, .checkboxDone:
            guard let box = markRect(kind, range: range) else { return }
            let s = box.width / 13
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.7, dy: 0.7), xRadius: 3 * s, yRadius: 3 * s)
            if kind == .checkboxDone {
                accentColor.setFill()
                path.fill()
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: box.minX + 3.2 * s, y: box.minY + 6.8 * s))
                tick.line(to: NSPoint(x: box.minX + 5.6 * s, y: box.minY + 9.2 * s))
                tick.line(to: NSPoint(x: box.minX + 9.8 * s, y: box.minY + 4.2 * s))
                tick.lineWidth = 1.8 * s
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
            guard let (bar, above, below) = quoteBar(range) else { return }
            accentColor.withAlphaComponent(0.7).setFill()
            // Square where it joins the next quote line, so the bar reads as one.
            let path = NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5)
            if above { path.append(NSBezierPath(rect: NSRect(x: bar.minX, y: bar.minY, width: bar.width, height: min(2, bar.height)))) }
            if below { path.append(NSBezierPath(rect: NSRect(x: bar.minX, y: bar.maxY - min(2, bar.height), width: bar.width, height: min(2, bar.height)))) }
            path.windingRule = .nonZero
            path.fill()

        case .codeLine:
            guard let card = codeCardRect(range) else { return }
            inkColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: card, xRadius: 6, yRadius: 6).fill()
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
        // The font is the item's own text's — not `self.font`, which is the
        // first character's, a hidden marker's near-zero font when the note
        // starts with a list, which put the box on the baseline, low and cut.
        let font = textFont(after: characters)
        let centre = origin.y + line.minY + location.y - font.capHeight / 2
        return NSRect(
            x: origin.x + line.minX + location.x,
            y: centre - used.height / 2,
            width: width,
            height: used.height
        )
    }

    /// A quote's bar: down the whole paragraph, wrapped lines included, and
    /// inside its lines — joined to the quote lines just above and below, so
    /// a quote of several lines has one bar, rounded only at its two ends.
    func quoteBarRect(_ range: NSRange) -> NSRect? { quoteBar(range)?.rect }

    func quoteBar(_ range: NSRange) -> (rect: NSRect, joinsAbove: Bool, joinsBelow: Bool)? {
        guard let layoutManager, let container = textContainer, let storage = textStorage else { return nil }
        let text = storage.string as NSString
        let paragraph = text.paragraphRange(for: range)
        let glyphs = layoutManager.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
        var union = NSRect.null
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
            union = union.union(rect)
        }
        guard !union.isNull else { return nil }
        func isQuote(_ location: Int) -> Bool {
            guard location >= 0, location < storage.length else { return false }
            let other = text.paragraphRange(for: NSRange(location: location, length: 0))
            return (text.substring(with: other) as String).trimmingCharacters(in: .whitespaces).hasPrefix(">")
        }
        let joinsAbove = isQuote(paragraph.location - 1)
        let joinsBelow = isQuote(NSMaxRange(paragraph))
        // Free ends stop at the text's own top and bottom, so the bar is
        // centred on the words, not on the line box (whose extra room is
        // above). Measured with the quote's own font: the "> " before it is
        // hidden in a near-zero one.
        let font = textFont(after: range)
        var firstBaseline: CGFloat?
        var lastBaseline: CGFloat = union.maxY
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, lineGlyphs, _ in
            let baseline = rect.minY + layoutManager.location(forGlyphAt: lineGlyphs.location).y
            if firstBaseline == nil { firstBaseline = baseline }
            lastBaseline = baseline
        }
        // Never past its lines, which are all a redraw of them repaints.
        let top = joinsAbove ? union.minY : max(union.minY, (firstBaseline ?? union.minY) - font.ascender)
        let bottom = joinsBelow ? union.maxY : min(union.maxY, lastBaseline - font.descender)
        let rect = NSRect(x: textContainerOrigin.x + container.lineFragmentPadding,
                          y: textContainerOrigin.y + top, width: 3, height: max(0, bottom - top))
        return (rect, joinsAbove, joinsBelow)
    }

    /// A code block's card: the whole block (not only the part being
    /// redrawn), from the text's left edge to the right margin, rounded.
    func codeCardRect(_ range: NSRange) -> NSRect? {
        guard let layoutManager, let container = textContainer, let storage = textStorage,
              range.location < storage.length else { return nil }
        var block = NSRange()
        _ = storage.attribute(MarkdownStyler.decorationKey, at: range.location, longestEffectiveRange: &block,
                              in: NSRange(location: 0, length: storage.length))
        let glyphs = layoutManager.glyphRange(forCharacterRange: block, actualCharacterRange: nil)
        var union = NSRect.null
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in union = union.union(rect) }
        guard !union.isNull else { return nil }
        let left = textContainerOrigin.x + container.lineFragmentPadding
        let right = textContainerOrigin.x + container.size.width - container.lineFragmentPadding
        return NSRect(x: left, y: textContainerOrigin.y + union.minY, width: right - left, height: union.height)
    }

    /// The rectangles a run of text covers, one per line, as tall as its
    /// font's letters rather than the whole line box.
    func textBoxes(_ range: NSRange) -> [NSRect] {
        guard let layoutManager, let container = textContainer, let storage = textStorage, range.length > 0,
              NSMaxRange(range) <= storage.length else { return [] }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var boxes: [NSRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, lineGlyphs, _ in
            let part = NSIntersectionRange(lineGlyphs, glyphs)
            guard part.length > 0 else { return }
            var span = layoutManager.boundingRect(forGlyphRange: part, in: container)
            // Without the line's trailing break.
            let characters = layoutManager.characterRange(forGlyphRange: part, actualGlyphRange: nil)
            if let last = (storage.string as NSString).substring(with: characters).last, last == "\n" {
                span.size.width = max(0, layoutManager.location(forGlyphAt: NSMaxRange(part) - 1).x + fragment.minX - span.minX)
            }
            let baseline = fragment.minY + layoutManager.location(forGlyphAt: part.location).y
            let font = (storage.attribute(.font, at: characters.location, effectiveRange: nil) as? NSFont) ?? self.bodyFont
            let top = baseline - font.ascender - 1
            let bottom = baseline - font.descender + 1
            boxes.append(NSRect(x: span.minX - 2, y: top, width: span.width + 4, height: bottom - top)
                .offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y))
        }
        return boxes
    }

    /// Every match, quietly; the current one stronger and outlined.
    private func drawFindMatches(in characters: NSRange) {
        guard !findMatches.isEmpty else { return }
        for (index, match) in findMatches.enumerated() where NSIntersectionRange(match, characters).length > 0 {
            let current = index == currentFindMatch
            for box in textBoxes(match) {
                let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
                highlightColor.withAlphaComponent(current ? 0.85 : 0.38).setFill()
                path.fill()
                if current {
                    inkColor.withAlphaComponent(0.55).setStroke()
                    path.lineWidth = 1
                    path.stroke()
                }
            }
        }
    }

    /// The font of the text that follows a marker on its line, or the body's
    /// when the item is empty.
    func textFont(after marker: NSRange) -> NSFont {
        guard let storage = textStorage else { return bodyFont }
        let text = storage.string as NSString
        let line = text.paragraphRange(for: marker)
        var index = NSMaxRange(marker)
        while index < NSMaxRange(line) {
            let character = text.character(at: index)
            if character == 0x0A { break }
            if let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont, font.pointSize > 1 {
                return font
            }
            index += 1
        }
        return bodyFont
    }

    // MARK: - Hidden list markers

    /// The bullet or checkbox run a character belongs to. Those are hidden
    /// characters standing in for a drawn shape, so they behave as one unit.
    private func hiddenMarker(at index: Int) -> NSRange? {
        guard let storage = textStorage, index >= 0, index < storage.length else { return nil }
        var run = NSRange()
        // An attachment line is one unit too: the caret stands before or after it.
        if let layout = storage.attribute(MarkdownStyler.attachmentKey, at: index, effectiveRange: nil) as? AttachmentLayout,
           NSMaxRange(layout.reference.range) <= storage.length {
            return layout.reference.range
        }
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
            replaceText(run, with: "")
            setSelectedRange(NSRange(location: run.location, length: 0))
            renumber(around: NSRange(location: run.location, length: 0))
            return
        }
        super.deleteBackward(sender)
    }

    /// Typing beside an attachment starts a line of its own, so the
    /// attachment's line stays whole.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let selection = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        if selection.length == 0, let layout = attachmentLine(touching: selection.location) {
            let typed = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
            if !typed.hasPrefix("\n") {
                if selection.location == NSMaxRange(layout.reference.range) {
                    super.insertText("\n" + typed, replacementRange: replacementRange)
                } else {
                    super.insertText(typed + "\n", replacementRange: replacementRange)
                    setSelectedRange(NSRange(location: selection.location + (typed as NSString).length, length: 0))
                }
                return
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// Space on a selected attachment shows it in Quick Look.
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags.isEmpty, event.charactersIgnoringModifiers == " ", let layout = selectedAttachment {
            quickLook(layout)
            return
        }
        super.keyDown(with: event)
    }

    /// Delete just before an attachment removes it whole.
    override func deleteForward(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length == 0, let layout = attachmentLine(touching: selection.location),
           layout.reference.range.location == selection.location {
            removeAttachment(layout)
            return
        }
        super.deleteForward(sender)
    }

    // MARK: - Dropping files

    func registerAttachmentDrops() {
        registerForDraggedTypes(registeredDraggedTypes + [.fileURL, .png, .tiff]
            + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingEntered(sender)
        return isEditable && library != nil && Self.canAttach(from: sender.draggingPasteboard) ? .copy : operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingUpdated(sender)
        return isEditable && library != nil && Self.canAttach(from: sender.draggingPasteboard) ? .copy : operation
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        guard isEditable, library != nil, Self.canAttach(from: board) else { return super.performDragOperation(sender) }
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        let at = NSRange(location: index, length: 0)
        let candidates = Self.candidates(from: board)
        if !candidates.isEmpty {
            insertAttachments(candidates, at: at)
            return true
        }
        let promises = board.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
        guard !promises.isEmpty else { return super.performDragOperation(sender) }
        receivePromises(promises, at: at)
        return true
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
            replaceText(change.range, with: change.string)
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

    /// A URL pasted over selected text becomes a link on that text. Files
    /// and pictures on the clipboard (a screenshot, say) become attachments.
    override func paste(_ sender: Any?) {
        let board = pasteSource
        if isEditable, library != nil, Self.pastesAsAttachment(board) {
            let candidates = Self.candidates(from: board)
            if !candidates.isEmpty {
                insertAttachments(candidates, at: selectedRange())
                return
            }
        }
        if isEditable, let pasted = board.string(forType: .string),
           let result = Formatting.pasteURL(currentEdit, pasted: pasted) {
            apply(result)
        } else if isEditable, board !== NSPasteboard.general, let pasted = board.string(forType: .string) {
            // The tests' own clipboard: the text as the system would paste it.
            insertText(pasted, replacementRange: selectedRange())
        } else {
            super.paste(sender)
        }
    }

    /// The right-click menu: the Format commands on top, above the standard
    /// items, so what the shortcuts do is discoverable where the text is.
    override func menu(for event: NSEvent) -> NSMenu? {
        if let layout = attachment(at: convert(event.locationInWindow, from: nil)) {
            select(layout)
            return menu(for: layout)
        }
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
        // A plain-text view only enables Paste for text: with a screenshot
        // alone on the clipboard, ⌘V did nothing at all.
        if item.action == #selector(paste(_:)), isEditable, library != nil, Self.pastesAsAttachment(pasteSource) {
            return true
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
    func replaceText(_ range: NSRange, with string: String) {
        guard let storage = textStorage else { return }
        if shouldChangeText(in: range, replacementString: string) {
            storage.replaceCharacters(in: range, with: string)
            didChangeText()
        }
    }

    // MARK: - Clicks

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // An image: a click selects it, a double click shows it in Quick
        // Look. A file's card opens it in its app.
        if let layout = attachment(at: point) {
            select(layout)
            if !layout.showsImage, layout.info != nil {
                openAttachment(layout)
            } else if event.clickCount >= 2 {
                quickLook(layout)
            }
            return
        }

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
                  let frame = markRect(.checkbox, range: range) else { return }
            // A little larger than the box, so a click near its edge counts.
            if frame.insetBy(dx: -4, dy: -4).contains(point) {
                hit = range
                stop.pointee = true
            }
        }
        return hit
    }

    /// ⌘Return ticks or unticks the task the caret is on, so a checklist
    /// needs no mouse.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if window?.firstResponder === self, flags == .command, event.keyCode == 36 || event.keyCode == 76,
           let box = checkboxOnCaretLine() {
            toggleCheckboxForAccessibility(markerRange: box)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The checkbox marker of the line the caret is on, if it has one.
    func checkboxOnCaretLine() -> NSRange? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let line = (storage.string as NSString).paragraphRange(for: NSRange(location: min(selectedRange().location, storage.length), length: 0))
        var hit: NSRange?
        storage.enumerateAttribute(MarkdownStyler.decorationKey, in: line) { value, range, stop in
            guard let raw = value as? String,
                  raw == MarkdownStyler.Decoration.checkbox.rawValue || raw == MarkdownStyler.Decoration.checkboxDone.rawValue
            else { return }
            hit = range
            stop.pointee = true
        }
        return hit
    }

    /// VoiceOver's press on a checklist box.
    func toggleCheckboxForAccessibility(markerRange: NSRange) {
        toggleCheckbox(markerRange: markerRange)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    /// Flips the character between the brackets.
    private func toggleCheckbox(markerRange: NSRange) {
        guard let storage = textStorage else { return }
        let marker = (storage.string as NSString).substring(with: markerRange) as NSString
        let bracket = marker.range(of: "[")
        guard bracket.location != NSNotFound, bracket.location + 1 < marker.length else { return }

        let state = NSRange(location: markerRange.location + bracket.location + 1, length: 1)
        let current = (storage.string as NSString).substring(with: state)
        replaceText(state, with: current == " " ? "x" : " ")
    }

    // MARK: - Hover

    /// What the pointer over a link or a file's card is told, and shown.
    static var linkHint: String { L("\u{2318}-click to open") }

    /// The hint for the point, if it is over a link: "⌘-click to open".
    func hoverHint(at point: NSPoint) -> String? {
        link(at: point) == nil ? nil : Self.linkHint
    }

    /// A hand over a link and over a file's card, which a click opens; the
    /// text's I-beam everywhere else.
    func hoverCursor(at point: NSPoint) -> NSCursor? {
        if link(at: point) != nil { return .pointingHand }
        if let layout = attachment(at: point), !layout.showsImage, layout.info != nil { return .pointingHand }
        return nil
    }

    private var hoverArea: NSTrackingArea?
    /// The link the hint is set for, so moving inside it changes nothing.
    private var hintedLink: NSRect?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        hoverCursor(at: point)?.set()
        // The hint is a tooltip on the link's own rectangle, so it comes and
        // goes with the pointer the way the system's tooltips do.
        if let rect = linkRect(at: point) {
            if hintedLink != rect {
                removeAllToolTips()
                addToolTip(rect, owner: Self.linkHint as NSString, userData: nil)
                hintedLink = rect
            }
        } else if let layout = attachment(at: point), let rect = attachmentRect(layout),
                  let hint = attachmentHint(layout) {
            // An image says its description; a card, what a click does.
            if hintedLink != rect {
                removeAllToolTips()
                addToolTip(rect, owner: hint as NSString, userData: nil)
                hintedLink = rect
            }
        } else if hintedLink != nil {
            removeAllToolTips()
            hintedLink = nil
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if hintedLink != nil {
            removeAllToolTips()
            hintedLink = nil
        }
    }

    /// The tooltip of an attachment: an image's description, or for a file
    /// "Click to open".
    func attachmentHint(_ layout: AttachmentLayout) -> String? {
        if layout.reference.isImage {
            let label = layout.reference.label.trimmingCharacters(in: .whitespaces)
            return label.isEmpty ? nil : label
        }
        return layout.info == nil ? nil : L("Click to open")
    }

    /// The rectangle of the link under the point, in view coordinates.
    private func linkRect(at point: NSPoint) -> NSRect? {
        guard link(at: point) != nil, let storage = textStorage, let layoutManager, let textContainer else { return nil }
        let index = characterIndexForInsertion(at: point)
        for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
            var run = NSRange()
            guard storage.attribute(MarkdownStyler.linkKey, at: candidate, effectiveRange: &run) != nil else { continue }
            let glyphs = layoutManager.glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            return layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        }
        return nil
    }

    func link(at point: NSPoint) -> URL? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        // Over the text itself, not past the end of a line.
        let glyph = layoutManager?.glyphIndex(for: NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y),
                                              in: textContainer!, fractionOfDistanceThroughGlyph: nil) ?? 0
        if let layoutManager, let textContainer {
            let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            guard box.insetBy(dx: -1, dy: -1).contains(point) else { return nil }
        }
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

// MARK: - VoiceOver

/// A checklist item's box, as VoiceOver sees it: a checkbox named by the
/// item's text, ticked or not, which pressing ticks or unticks.
final class ChecklistBoxElement: NSAccessibilityElement {
    var toggle: () -> Void = {}
    override func accessibilityPerformPress() -> Bool {
        toggle()
        return true
    }
}

extension MarkdownTextView {
    /// The text as usual, and a checkbox for every checklist item. The boxes
    /// are drawn over hidden "[ ]" characters, which VoiceOver would
    /// otherwise read as punctuation.
    override func accessibilityChildren() -> [Any]? {
        (super.accessibilityChildren() ?? []) + checklistBoxes() + attachmentElements()
    }

    /// Images read as images, with their description; files as buttons with
    /// their name and size, which pressing opens.
    func attachmentElements() -> [NSAccessibilityElement] {
        guard let window else { return [] }
        return allAttachmentLayouts.compactMap { layout -> NSAccessibilityElement? in
            guard let rect = attachmentRect(layout) else { return nil }
            let element = ChecklistBoxElement()
            // The right click's commands, as actions VoiceOver lists.
            element.setAccessibilityCustomActions(menu(for: layout).items.filter { !$0.isSeparatorItem && $0.isEnabled }.map { item in
                // The item (and the closure it carries) lives as long as the action.
                NSAccessibilityCustomAction(name: item.title) {
                    guard let action = item.action else { return false }
                    return NSApp.sendAction(action, to: item.target, from: item)
                }
            })
            element.setAccessibilityParent(self)
            element.setAccessibilityFrame(window.convertToScreen(convert(rect, to: nil)))
            element.setAccessibilityLabel(AccessibilityText.attachment(isImage: layout.reference.isImage,
                                                                       label: layout.reference.label,
                                                                       name: layout.info?.name,
                                                                       size: layout.info?.sizeText))
            if layout.reference.isImage {
                element.setAccessibilityRole(.image)
                element.toggle = { [weak self] in self?.quickLook(layout) }
            } else {
                element.setAccessibilityRole(.button)
                element.toggle = { [weak self] in self?.openAttachment(layout) }
            }
            return element
        }
    }

    func checklistBoxes() -> [ChecklistBoxElement] {
        guard let storage = textStorage, storage.length > 0, let window else { return [] }
        var boxes: [ChecklistBoxElement] = []
        let text = storage.string as NSString
        storage.enumerateAttribute(MarkdownStyler.decorationKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let raw = value as? String,
                  let kind = MarkdownStyler.Decoration(rawValue: raw), kind == .checkbox || kind == .checkboxDone,
                  let frame = markRect(kind, range: range) else { return }
            let line = text.paragraphRange(for: range)
            let label = text.substring(with: NSRange(location: NSMaxRange(range), length: max(0, NSMaxRange(line) - NSMaxRange(range))))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let box = ChecklistBoxElement()
            box.setAccessibilityRole(.checkBox)
            box.setAccessibilityLabel(label.isEmpty ? L("Empty task") : label)
            box.setAccessibilityValue(kind == .checkboxDone ? 1 : 0)
            box.setAccessibilityParent(self)
            box.setAccessibilityFrame(window.convertToScreen(convert(frame, to: nil)))
            box.toggle = { [weak self] in self?.toggleCheckboxForAccessibility(markerRange: range) }
            boxes.append(box)
        }
        return boxes
    }
}
