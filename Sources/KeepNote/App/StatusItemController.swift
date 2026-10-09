import AppKit

/// The menu bar icon. Owns the `NSStatusItem`; the menu itself comes from the
/// coordinator, so the pill's right-click menu and this one never drift apart.
@MainActor
final class StatusItemController {
    private var item: NSStatusItem?
    private let makeMenu: () -> NSMenu

    init(makeMenu: @escaping () -> NSMenu) {
        self.makeMenu = makeMenu
    }

    var isShown: Bool { item != nil }

    func show() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.glyph()
        item.button?.toolTip = "KeepNote"
        item.menu = makeMenu()
        self.item = item
    }

    func hide() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    /// The glyph is drawn at 18 pt as a template, so the system tints it for
    /// light, dark and highlighted states. `StatusGlyph.png`, `@2x` and `@3x`
    /// (18, 36 and 54 px) all go into one image, and AppKit picks the one for
    /// the screen's scale. If the files are missing, an SF Symbol stands in
    /// rather than an empty, unclickable item.
    private static func glyph() -> NSImage {
        if let directory = Bundle.main.resourceURL, let image = glyph(in: directory) {
            return image
        }
        let fallback = NSImage(systemSymbolName: "note.text", accessibilityDescription: "KeepNote") ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }

    static let glyphSize = NSSize(width: 18, height: 18)

    /// One 18 x 18 pt template image with a representation per file found in
    /// `directory`; `nil` when there is none.
    static func glyph(in directory: URL) -> NSImage? {
        let image = NSImage(size: glyphSize)
        for name in ["StatusGlyph.png", "StatusGlyph@2x.png", "StatusGlyph@3x.png"] {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else { continue }
            rep.size = glyphSize
            image.addRepresentation(rep)
        }
        guard !image.representations.isEmpty else { return nil }
        image.isTemplate = true
        image.accessibilityDescription = "KeepNote"
        return image
    }
}
