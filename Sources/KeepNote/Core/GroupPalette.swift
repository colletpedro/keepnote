import Foundation

/// The twelve colours of a group, as plain numbers, so the palette can be
/// checked without AppKit: the exact values, and the contrast of the text
/// drawn on each.
///
/// They are not the five papers of the notes. A group's tab is a different
/// thing from a note's, and a different colour says so at a glance; they are
/// deeper, and the text on them is chosen per colour, light on the deep ones
/// and dark on the light ones, so that every pair reads at 4.5:1 or better.
///
/// Hex is 0xRRGGBB, sRGB.
enum GroupPalette {
    struct Swatch: Equatable {
        /// The face of the tab, the header of an open group and the colour
        /// dot in lists.
        let fill: UInt32
        /// Every piece of text drawn on `fill`: the name and the count.
        let ink: UInt32
    }

    static let dark: UInt32 = 0x1F1D1A
    static let light: UInt32 = 0xFFFFFF

    static let red = Swatch(fill: 0xC53030, ink: light)
    static let orange = Swatch(fill: 0xE8782E, ink: dark)
    static let amber = Swatch(fill: 0xF0B429, ink: dark)
    static let lime = Swatch(fill: 0xA3C93A, ink: dark)
    static let green = Swatch(fill: 0x45B574, ink: dark)
    static let teal = Swatch(fill: 0x137575, ink: light)
    static let cyan = Swatch(fill: 0x3FB6D9, ink: dark)
    static let blue = Swatch(fill: 0x2F6FD6, ink: light)
    static let indigo = Swatch(fill: 0x4B4FC4, ink: light)
    static let purple = Swatch(fill: 0x8B4FC9, ink: light)
    static let pink = Swatch(fill: 0xE46EA6, ink: dark)
    static let slate = Swatch(fill: 0x5F6B7A, ink: light)

    /// The least contrast any text on a group colour may have (WCAG AA).
    static let minimumContrast = 4.5

    /// A colour a little darker or lighter, for the two sheets behind a
    /// closed group and for its outline: `amount` 0 is `hex`, 1 is `toward`.
    static func mixed(_ hex: UInt32, toward other: UInt32, by amount: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let a = Double((hex >> shift) & 0xFF)
            let b = Double((other >> shift) & 0xFF)
            return UInt32((a + (b - a) * amount).rounded())
        }
        return (channel(16) << 16) | (channel(8) << 8) | channel(0)
    }
}
