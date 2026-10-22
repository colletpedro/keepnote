import AppKit

// MARK: - Mentions and links

extension MarkdownTextView {
    /// The eight colours of a site's icon, fixed so a site keeps its colour
    /// on every paper.
    static let mentionColors: [NSColor] = [
        NSColor(srgbRed: 0.93, green: 0.45, blue: 0.16, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.48, blue: 0.86, alpha: 1),
        NSColor(srgbRed: 0.10, green: 0.60, blue: 0.58, alpha: 1),
        NSColor(srgbRed: 0.27, green: 0.62, blue: 0.27, alpha: 1),
        NSColor(srgbRed: 0.55, green: 0.36, blue: 0.82, alpha: 1),
        NSColor(srgbRed: 0.85, green: 0.30, blue: 0.52, alpha: 1),
        NSColor(srgbRed: 0.80, green: 0.25, blue: 0.22, alpha: 1),
        NSColor(srgbRed: 0.35, green: 0.38, blue: 0.80, alpha: 1),
    ]

    /// Where a mention's icon is drawn: in the room its hidden "[" keeps,
    /// centred on the title's capitals, like the list marks.
    func mentionIconRect(_ range: NSRange) -> NSRect? {
        guard let layoutManager, range.length > 0 else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let location = layoutManager.location(forGlyphAt: glyphs.location)
        let font = textFont(after: range)
        let side = (15 * textScale).rounded()
        let centre = textContainerOrigin.y + line.minY + location.y - font.capHeight / 2
        return NSRect(x: textContainerOrigin.x + line.minX + location.x + 1 * textScale,
                      y: (centre - side / 2).rounded(), width: side, height: side)
    }

    func drawMentionIcons(in characters: NSRange) {
        guard let storage = textStorage else { return }
        storage.enumerateAttribute(MarkdownStyler.mentionKey, in: characters) { value, range, _ in
            guard let url = value as? String, let rect = mentionIconRect(range) else { return }
            Self.mentionColors[LinkMention.colorIndex(for: url)].setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.24, yRadius: rect.width * 0.24).fill()
            let letter = LinkMention.initial(for: url) as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: rect.height * 0.66, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let size = letter.size(withAttributes: attributes)
            letter.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
        }
    }

    // MARK: Paste as mention

    /// After an address is pasted on its own: a menu at the caret offers it
    /// as a mention or as the address it is, as Notion does. Esc keeps the
    /// address.
    func offerMention(for range: NSRange) {
        guard isEditable, NSMaxRange(range) <= (string as NSString).length,
              Formatting.url(from: (string as NSString).substring(with: range)) != nil,
              let layoutManager, let textContainer else { return }
        let menu = NSMenu()
        let mention = NSMenuItem(title: L("Mention"), action: #selector(ClosureMenuTarget.run(_:)), keyEquivalent: "")
        let mentionTarget = ClosureMenuTarget { [weak self] in self?.makeMention(range: range) }
        mention.target = mentionTarget
        mention.representedObject = mentionTarget
        mention.image = NSImage(systemSymbolName: "link.badge.plus", accessibilityDescription: nil)
        let keep = NSMenuItem(title: L("URL"), action: nil, keyEquivalent: "")
        keep.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        keep.isEnabled = true
        keep.target = self
        keep.action = #selector(keepPastedURL(_:))
        let header = NSMenuItem(title: L("Paste as"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(mention)
        menu.addItem(keep)
        menu.autoenablesItems = false
        let glyph = layoutManager.glyphIndexForCharacter(at: max(0, NSMaxRange(range) - 1))
        let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        let point = NSPoint(x: box.maxX + textContainerOrigin.x, y: box.maxY + textContainerOrigin.y + 4)
        menu.popUp(positioning: mention, at: point, in: self)
    }

    @objc private func keepPastedURL(_ sender: Any?) {}

    /// The address at `range` becomes a mention of it.
    func makeMention(range: NSRange) {
        guard NSMaxRange(range) <= (string as NSString).length,
              let url = Formatting.url(from: (string as NSString).substring(with: range)) else { return }
        let token = LinkMention.token(url: Formatting.destination(url))
        replaceText(range, with: token)
        setSelectedRange(NSRange(location: range.location + (token as NSString).length, length: 0))
    }

    // MARK: The right click on a link

    /// Open Link, Copy Link, and Show as Mention or Show as Link, above the
    /// usual items.
    func linkMenuItems(at point: NSPoint) -> [NSMenuItem] {
        guard let url = link(at: point) else { return [] }
        let index = characterIndexForInsertion(at: point)
        var items: [NSMenuItem] = []
        func add(_ title: String, _ action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(ClosureMenuTarget.run(_:)), keyEquivalent: "")
            let target = ClosureMenuTarget(action)
            item.target = target
            item.representedObject = target
            items.append(item)
        }
        add(L("Open Link")) { [weak self] in self?.openURL(url) }
        add(L("Copy Link")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
        if isEditable, let span = LinkMention.span(at: index, in: string) ?? LinkMention.span(at: index - 1, in: string) {
            let toMention = span.kind != .mention
            add(toMention ? L("Show as Mention") : L("Show as Link")) { [weak self] in
                self?.replaceText(span.range, with: LinkMention.converted(span, toMention: toMention))
            }
        }
        return items
    }
}
