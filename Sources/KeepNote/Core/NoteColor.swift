import AppKit
import SwiftUI

/// The palette: five paper pastels, pickable from inside any note at any time.
///
/// Raw values are part of the on-disk format and must never change. The three
/// gaps (0, 3, 7) are colours an earlier build shipped; `resolve(rawValue:)`
/// folds them into their nearest survivor so old notes and old `.hmnote` files
/// keep a sensible colour instead of all collapsing to the default.
enum NoteColor: Int, CaseIterable, Codable, Sendable {
    case butter = 1
    case coral = 2
    case mint = 6
    case sky = 5
    case lilac = 4

    /// What a new note gets when nothing else decides.
    static let `default` = NoteColor.butter

    /// The only way colours should be read back from disk.
    static func resolve(rawValue: Int) -> NoteColor {
        if let exact = NoteColor(rawValue: rawValue) { return exact }
        switch rawValue {
        case 0: return .butter   // was sand
        case 3: return .coral    // was blush
        case 7: return .mint     // was sage
        default: return .default
        }
    }

    var displayName: String {
        switch self {
        case .butter: return L("Butter")
        case .coral: return L("Coral")
        case .mint: return L("Mint")
        case .sky: return L("Sky")
        case .lilac: return L("Lilac")
        }
    }

    /// The numbers behind every colour below; see `NotePalette`.
    private var swatch: NotePalette.Swatch {
        switch self {
        case .butter: return NotePalette.butter
        case .coral: return NotePalette.coral
        case .mint: return NotePalette.mint
        case .sky: return NotePalette.sky
        case .lilac: return NotePalette.lilac
        }
    }

    private static func color(_ hex: UInt32) -> NSColor {
        let (r, g, b) = NotePalette.components(hex)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// The paper the note is written on, and the fill of its tab in the deck.
    ///
    /// The same in Aqua and Dark Aqua. A note is a piece of paper, and paper
    /// does not turn brown when the desktop does. The app's own chrome still
    /// follows the system appearance; only the paper stays paper.
    var surface: NSColor { Self.color(swatch.paper) }

    /// The spine of an open note — close button and rotated title — and the
    /// fill of the colour swatches, the resting stripe's dashes and the
    /// markers in lists. Saturated enough to read beside the paper.
    var spine: NSColor { Self.color(swatch.spine) }

    /// Text and marks drawn on the paper: list numbers, links, bullets,
    /// checkboxes, the caret. Dark enough for 4.5:1 on `surface`.
    var accent: NSColor { Self.color(swatch.accent) }

    /// The status line and other quiet text on the paper — the body's ink
    /// itself with Increase contrast.
    @MainActor var secondaryInk: NSColor {
        DisplayOptions.increaseContrast ? ink : Self.color(swatch.secondary)
    }

    /// The tear line, the card outlines and the footer buttons' borders: faint,
    /// or firm with Increase contrast.
    @MainActor var rule: NSColor {
        ink.withAlphaComponent(DisplayOptions.increaseContrast ? 0.6 : 0.2)
    }

    /// Body text on top of `surface`. The same dark on every paper.
    var ink: NSColor { Self.color(NotePalette.ink) }

    /// Cycling walks the palette in the order it is shown, not in raw-value
    /// order — the raw values have gaps.
    var next: NoteColor {
        let all = NoteColor.allCases
        guard let index = all.firstIndex(of: self) else { return .default }
        return all[(index + 1) % all.count]
    }

    var previous: NoteColor {
        let all = NoteColor.allCases
        guard let index = all.firstIndex(of: self) else { return .default }
        return all[(index - 1 + all.count) % all.count]
    }

    var surfaceSwiftUI: Color { Color(nsColor: surface) }
    var spineSwiftUI: Color { Color(nsColor: spine) }
    var inkSwiftUI: Color { Color(nsColor: ink) }
    @MainActor var secondaryInkSwiftUI: Color { Color(nsColor: secondaryInk) }
    @MainActor var ruleSwiftUI: Color { Color(nsColor: rule) }
    /// The tear line on an open note, the peek and All Notes' card.
    @MainActor var perforationSwiftUI: Color {
        inkSwiftUI.opacity(DisplayOptions.increaseContrast ? 0.65 : 0.28)
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
