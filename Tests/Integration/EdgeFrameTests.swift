import AppKit

/// The peek and the anchored note come out of the deck towards the middle of
/// the screen, whichever edge the deck is on.
@MainActor
func runEdgeFrameTests() {
    let area = NSRect(x: 72, y: 0, width: 1440, height: 900)   // a left Dock
    let deckWidth = EdgeMetrics.tabWidth + EdgeMetrics.hoverGutter
    let tab = NSRect(x: 0, y: 400, width: EdgeMetrics.tabWidth, height: EdgeMetrics.tabHeight)

    let rightPeek = NotePreviewController.frame(for: tab.offsetBy(dx: area.maxX - 48, dy: 0), deckWidth: deckWidth, area: area, edge: .right)
    let leftPeek = NotePreviewController.frame(for: tab.offsetBy(dx: area.minX, dy: 0), deckWidth: deckWidth, area: area, edge: .left)
    let outside = deckWidth - EdgeMetrics.previewTuck
    expect("peek (right): its end tucked under the deck", String(Double(rightPeek.maxX)), String(Double(area.maxX - outside)))
    expect("peek (left): its end tucked under the deck", String(Double(leftPeek.minX)), String(Double(area.minX + outside)))
    expect("peek: the same size on both edges", "\(rightPeek.size)", "\(leftPeek.size)")
    expect("peek: centred on the tab", String(Double(leftPeek.midY)), String(Double(tab.midY)))
    let rightStart = NotePreviewController.start(for: rightPeek, edge: .right)
    let leftStart = NotePreviewController.start(for: leftPeek, edge: .left)
    expect("peek (right): starts as a tab by the edge", String(Double(rightStart.maxX)), String(Double(rightPeek.maxX)))
    expect("peek (left): starts as a tab by the edge", String(Double(leftStart.minX)), String(Double(leftPeek.minX)))

    let rightNote = NoteWindowController.anchoredFrame(in: area, centerY: 450, edge: .right)
    let leftNote = NoteWindowController.anchoredFrame(in: area, centerY: 450, edge: .left)
    expect("anchored (right): flush with the screen edge, under the deck", String(Double(rightNote.maxX)), String(Double(area.maxX)))
    expect("anchored (left): beside the tabs, its spine clear of them",
           String(Double(leftNote.minX)), String(Double(area.minX + EdgeMetrics.tabWidth)))
    expect("anchored: the same size", "\(rightNote.size)", "\(leftNote.size)")
    expectTrue("anchored: kept on screen", leftNote.minY >= area.minY && leftNote.maxY <= area.maxY)
}
