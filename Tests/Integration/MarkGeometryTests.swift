import AppKit
import CryptoKit

// MARK: - List marks sit on the text, inside their own line

/// For every Text size, every kind of list mark — bullets at three levels,
/// numbers, open and ticked tasks — on a note that starts with a list (the
/// case that used to put the box on the baseline) and in its middle:
///
/// - drawn, the mark's middle is within 0.5 pt of the middle of the capitals
///   of the words beside it, measured on the rendered pixels;
/// - the mark is drawn inside its own line, so a redraw of that line alone
///   draws it whole.
@MainActor
func runMarkGeometryTests() {
    let store = reopened(scratchDirectory().appendingPathComponent("marks.sqlite"), key: SymmetricKey(size: .bits256))
    let saved = AppSettings.shared.textSize
    defer { AppSettings.shared.textSize = saved }
    let body = """
    - [ ] HHHH
    - [x] HHHH
    - HHHH
        - HHHH
            - HHHH
    1. HHHH
    Plain line
    - [ ] HHHH
    12. HHHH
    > quoted
    ---
    """
    for size in TextSize.allCases {
        AppSettings.shared.textSize = size
        let note = try! store.create(color: .sky, title: "Marks", body: body)
        let window = NoteWindowController(note: note, store: store, originFrame: nil, cascadeIndex: 0, floating: true)
        window.window.contentView?.layoutSubtreeIfNeeded()
        spin(0.25)
        guard let view = window.window.contentView.flatMap(textView(in:)) as? MarkdownTextView,
              let layoutManager = view.layoutManager, let storage = view.textStorage else {
            expectTrue("marks (\(size)): the editor is there", false)
            continue
        }
        // The caret on the plain line, so no list line shows its source.
        let plain = (view.string as NSString).range(of: "Plain line")
        view.setSelectedRange(NSRange(location: plain.location + 2, length: 0))
        view.layoutSubtreeIfNeeded()
        spin(0.05)

        // The view drawn, at the screen's 2x.
        let bounds = view.bounds
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        /// The vertical middle, in points, of what is drawn (not clear) in `rect`.
        func inkMiddle(_ rect: NSRect) -> CGFloat? {
            var top = Int.max, bottom = Int.min
            let x0 = max(0, Int(rect.minX * 2)), x1 = min(rep.pixelsWide - 1, Int(rect.maxX * 2))
            let y0 = max(0, Int(rect.minY * 2)), y1 = min(rep.pixelsHigh - 1, Int(rect.maxY * 2))
            guard x0 <= x1, y0 <= y1 else { return nil }
            for y in y0...y1 {
                for x in x0...x1 {
                    var pixel = [Int](repeating: 0, count: 4)
                    rep.getPixel(&pixel, atX: x, y: y)
                    if pixel[3] > 110 {   // more than ~43% covered
                        top = min(top, y)
                        bottom = max(bottom, y)
                    }
                }
            }
            guard top <= bottom else { return nil }
            // Bitmap rows run down from the view's top, like the flipped view.
            return (CGFloat(top) + CGFloat(bottom + 1)) / 4
        }

        var checked = 0
        let text = view.string as NSString
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines]) { line, range, _, _ in
            guard let line, line.contains("HHHH") else { return }
            let content = text.range(of: "HHHH", range: range)
            let glyphs = layoutManager.glyphRange(forCharacterRange: content, actualCharacterRange: nil)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
            let words = layoutManager.boundingRect(forGlyphRange: glyphs, in: view.textContainer!)
                .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
            let mark = NSRect(x: view.textContainerOrigin.x, y: fragment.minY,
                              width: words.minX - view.textContainerOrigin.x - 1, height: fragment.height)
            let what = "\(size) \"\(line.trimmingCharacters(in: .whitespaces).prefix(6))\""
            guard let textMiddle = inkMiddle(NSRect(x: words.minX, y: fragment.minY, width: words.width, height: fragment.height)),
                  let markMiddle = inkMiddle(mark) else {
                expectTrue("marks: \(what): drawn", false)
                return
            }
            expectTrue("marks: \(what): the mark's middle is on the text's (\(String(format: "%.2f", markMiddle - textMiddle)) pt)",
                       abs(markMiddle - textMiddle) <= 0.5)
            checked += 1
            // Drawn inside its own line.
            var markRange = NSRange()
            if let raw = storage.attribute(MarkdownStyler.decorationKey, at: range.location + (line.count - line.drop { $0 == " " }.count),
                                           effectiveRange: &markRange) as? String,
               let kind = MarkdownStyler.Decoration(rawValue: raw), let drawn = view.markRect(kind, range: markRange) {
                expectTrue("marks: \(what): inside its line", fragment.contains(drawn))
            }
        }
        expect("marks (\(size)): every item measured", String(checked), "8")

        // The quote's bar, the code card and an image stay inside the lines
        // they belong to, and the bar is centred on the quote's words.
        let quote = (view.string as NSString).range(of: "> quoted")
        if let bar = view.quoteBarRect(NSRange(location: quote.location, length: 2)) {
            let glyphs = layoutManager.glyphRange(forCharacterRange: quote, actualCharacterRange: nil)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
            expectTrue("marks (\(size)): the quote's bar inside its line", fragment.contains(bar))
            let words = (view.string as NSString).range(of: "quoted")
            let wordGlyphs = layoutManager.glyphRange(forCharacterRange: words, actualCharacterRange: nil)
            let baseline = fragment.minY + layoutManager.location(forGlyphAt: wordGlyphs.location).y
            let font = view.textFont(after: NSRange(location: quote.location, length: 2))
            let wordsMiddle = baseline - (font.ascender + font.descender) / 2
            expectTrue("marks (\(size)): the quote's bar centred on its words (\(String(format: "%.2f", bar.midY - wordsMiddle)) pt)",
                       abs(bar.midY - wordsMiddle) <= 0.5)
        } else {
            expectTrue("marks (\(size)): the quote has a bar", false)
        }
        window.close()
    }
}
