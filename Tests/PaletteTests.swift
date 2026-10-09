import Foundation

func runPaletteTests() {
    expect("ink", String(NotePalette.ink, radix: 16), "1f1d1a")

    let table: [(String, NotePalette.Swatch, [UInt32])] = [
        ("butter", NotePalette.butter, [0xF7E3A1, 0xEBC550, 0x7A5A00, 0x57503D]),
        ("coral", NotePalette.coral, [0xF6C1B1, 0xEE9279, 0x8F2F15, 0x574841]),
        ("mint", NotePalette.mint, [0xBFE5CC, 0x86CDA1, 0x1F6B45, 0x495148]),
        ("sky", NotePalette.sky, [0xBCD9F2, 0x86BCEB, 0x1F5C99, 0x484E52]),
        ("lilac", NotePalette.lilac, [0xD8CDF2, 0xB09EEA, 0x5B3FA8, 0x4F4B52]),
    ]
    for (name, swatch, hexes) in table {
        expectTrue("\(name): values", [swatch.paper, swatch.spine, swatch.accent, swatch.secondary] == hexes)
        // Text on the paper has to be readable: WCAG AA for body text.
        for (what, ink) in [("ink", NotePalette.ink), ("accent", swatch.accent), ("secondary", swatch.secondary)] {
            let ratio = NotePalette.contrast(ink, swatch.paper)
            expectTrue("\(name): \(what) on paper is at least 4.5:1 (got \(String(format: "%.2f", ratio)))", ratio >= 4.5)
        }
    }

    expectTrue("contrast: black on white is 21", abs(NotePalette.contrast(0x000000, 0xFFFFFF) - 21) < 0.001)
    expectTrue("contrast: a colour against itself is 1", abs(NotePalette.contrast(0x7A5A00, 0x7A5A00) - 1) < 0.001)
    expectTrue("components", NotePalette.components(0xFF8000).g > 0.5 && NotePalette.components(0xFF8000).b == 0)
}
