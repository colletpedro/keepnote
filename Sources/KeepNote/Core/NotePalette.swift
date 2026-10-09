import Foundation

/// The five note colours as plain numbers, so the palette can be checked
/// without AppKit: the exact values, and the contrast of text on paper.
///
/// Hex is 0xRRGGBB, sRGB. `NoteColor` turns these into `NSColor`.
enum NotePalette {
    struct Swatch: Equatable {
        /// The sheet the note is written on.
        let paper: UInt32
        /// The spine: the strip with the close button and the rotated title.
        /// Also the fill of the colour swatches in the footer.
        let spine: UInt32
        /// Text and marks drawn on the paper: numbering, links, bullets,
        /// checkboxes, the caret.
        let accent: UInt32
        /// Secondary text on the paper: the status line, placeholders.
        let secondary: UInt32
    }

    /// Primary text, the same on every paper.
    static let ink: UInt32 = 0x1F1D1A

    static let butter = Swatch(paper: 0xF7E3A1, spine: 0xEBC550, accent: 0x7A5A00, secondary: 0x57503D)
    static let coral = Swatch(paper: 0xF6C1B1, spine: 0xEE9279, accent: 0x8F2F15, secondary: 0x574841)
    static let mint = Swatch(paper: 0xBFE5CC, spine: 0x86CDA1, accent: 0x1F6B45, secondary: 0x495148)
    static let sky = Swatch(paper: 0xBCD9F2, spine: 0x86BCEB, accent: 0x1F5C99, secondary: 0x484E52)
    static let lilac = Swatch(paper: 0xD8CDF2, spine: 0xB09EEA, accent: 0x5B3FA8, secondary: 0x4F4B52)

    static func components(_ hex: UInt32) -> (r: Double, g: Double, b: Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    /// WCAG relative luminance.
    static func luminance(_ hex: UInt32) -> Double {
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let (r, g, b) = components(hex)
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG contrast ratio, 1...21.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
