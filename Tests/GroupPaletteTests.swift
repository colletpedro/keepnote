import Foundation

func runGroupPaletteTests() {
    expectTrue("groups: twelve colours", GroupColor.allCases.count == 12)
    expectTrue("groups: raw values 1 to 12, in order",
               GroupColor.allCases.map(\.rawValue) == Array(1...12))
    expectTrue("groups: every fill is its own",
               Set(GroupColor.allCases.map(\.swatch.fill)).count == 12)

    // Not the papers of the notes: a group's tab says it is not a note.
    let papers = Set([NotePalette.butter, NotePalette.coral, NotePalette.mint, NotePalette.sky, NotePalette.lilac]
        .flatMap { [$0.paper, $0.spine] })
    expectTrue("groups: no group colour is a note's paper or spine",
               GroupColor.allCases.allSatisfy { !papers.contains($0.swatch.fill) })

    // Every piece of text drawn on a group colour (the name, the count, in a
    // closed tab and in an open header) is `ink` on `fill`.
    for color in GroupColor.allCases {
        let swatch = color.swatch
        let ratio = NotePalette.contrast(swatch.ink, swatch.fill)
        expectTrue("groups: \(color) text is at least 4.5:1 (got \(String(format: "%.2f", ratio)))",
                   ratio >= GroupPalette.minimumContrast)
        expectTrue("groups: \(color) ink is the dark ink or white",
                   swatch.ink == GroupPalette.dark || swatch.ink == GroupPalette.light)
        // The better of the two inks is the one chosen, so no colour reads worse than it has to.
        let other = swatch.ink == GroupPalette.dark ? GroupPalette.light : GroupPalette.dark
        expectTrue("groups: \(color) has the better ink of the two",
                   ratio >= NotePalette.contrast(other, swatch.fill))
        expectTrue("groups: \(color) has a name", !color.displayName.isEmpty)
    }
    expectTrue("groups: every name is its own", Set(GroupColor.allCases.map(\.displayName)).count == 12)
    expect("groups: the least contrast of the palette is above AA", String(GroupColor.allCases
        .map { NotePalette.contrast($0.swatch.ink, $0.swatch.fill) }.min()! >= 4.5), "true")

    expectTrue("groups: a colour this build does not know is the default", GroupColor.resolve(rawValue: 99) == .default)
    expectTrue("groups: 0 is not a colour either", GroupColor.resolve(rawValue: 0) == .default)
    expectTrue("groups: raw values read back", GroupColor.allCases.allSatisfy { GroupColor.resolve(rawValue: $0.rawValue) == $0 })

    // New groups walk the palette and come back round.
    var walked = GroupColor.red
    var seen: [GroupColor] = []
    for _ in 0..<12 { seen.append(walked); walked = walked.next }
    expectTrue("groups: next visits all twelve", Set(seen).count == 12)
    expectTrue("groups: and then starts over", walked == .red)

    // The sheets behind a closed group.
    expectTrue("groups: mixing by nothing is the colour", GroupPalette.mixed(0x2F6FD6, toward: 0x000000, by: 0) == 0x2F6FD6)
    expectTrue("groups: mixing all the way is the other colour", GroupPalette.mixed(0x2F6FD6, toward: 0x102030, by: 1) == 0x102030)
}
