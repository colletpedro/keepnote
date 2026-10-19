import CoreGraphics

/// The deck beside the Dock, on whichever side either is.
func runDeckPlacementTests() {
    func rect(_ r: CGRect) -> String { "\(Int(r.minX)) \(Int(r.minY)) \(Int(r.width)) \(Int(r.height))" }
    // A 1512 × 982 pt screen, menu bar 33 pt.
    let noDock = CGRect(x: 0, y: 0, width: 1512, height: 949)
    let leftDock = CGRect(x: 72, y: 0, width: 1440, height: 949)   // Dock on the left, 72 pt
    let rightDock = CGRect(x: 0, y: 0, width: 1440, height: 949)
    let bottomDock = CGRect(x: 0, y: 70, width: 1512, height: 879)
    let pill: CGFloat = 60
    let deckWidth = Int(EdgeMetrics.tabWidth + EdgeMetrics.hoverGutter)

    expect("placement: stripe on the left edge, no Dock",
           rect(DeckPlacement.pillFrame(height: pill, in: noDock, edge: .left)), "0 444 12 60")
    expect("placement: stripe beside a left Dock",
           rect(DeckPlacement.pillFrame(height: pill, in: leftDock, edge: .left)), "72 444 12 60")
    expect("placement: on the right edge a left Dock changes nothing",
           rect(DeckPlacement.pillFrame(height: pill, in: leftDock, edge: .right)), "1500 444 12 60")
    expect("placement: stripe beside a right Dock",
           rect(DeckPlacement.pillFrame(height: pill, in: rightDock, edge: .right)), "1428 444 12 60")
    expect("placement: a bottom Dock moves the middle up",
           rect(DeckPlacement.pillFrame(height: pill, in: bottomDock, edge: .left)), "0 479 12 60")

    expect("placement: the open deck beside a left Dock",
           rect(DeckPlacement.deckFrame(deckHeight: 500, in: leftDock, edge: .left)), "72 224 \(deckWidth) 500")
    expect("placement: the open deck beside a right Dock",
           rect(DeckPlacement.deckFrame(deckHeight: 500, in: rightDock, edge: .right)),
           "\(1440 - deckWidth) 224 \(deckWidth) 500")
    expect("placement: never taller than the visible frame",
           rect(DeckPlacement.deckFrame(deckHeight: 2000, in: leftDock, edge: .left)), "72 0 \(deckWidth) 949")
    expect("placement: the height the deck gets", String(Int(DeckPlacement.usableHeight(in: leftDock))), "925")
}
