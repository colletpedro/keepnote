import AppKit
import SwiftUI

extension GroupColor {
    private static func color(_ hex: UInt32) -> NSColor {
        let (r, g, b) = NotePalette.components(hex)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// The face of the tab. The same in light and dark, like paper.
    var fill: NSColor { Self.color(swatch.fill) }

    /// The name and the count on the face.
    var ink: NSColor { Self.color(swatch.ink) }

    /// The two sheets behind a closed group (`depth` 1 is the nearer), and
    /// its outline: the face shifted toward the dark ink, so they read on any
    /// desktop.
    func sheet(_ depth: Int) -> NSColor {
        Self.color(GroupPalette.mixed(swatch.fill, toward: GroupPalette.dark, by: depth <= 1 ? 0.22 : 0.38))
    }

    var fillSwiftUI: Color { Color(nsColor: fill) }
    var inkSwiftUI: Color { Color(nsColor: ink) }
}
