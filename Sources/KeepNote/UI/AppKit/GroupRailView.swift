import AppKit

/// The strip that ties an open group's notes to its header: in the group's
/// colour, it leaves the foot of the header sideways, then runs down the inner
/// side of the group's notes to the last one, where it ends rounded.
///
/// Drawn for the right edge and mirrored for the left. It springs with the
/// tabs it follows (`SpringView`), so it scrolls with them, and it is never
/// under the cursor: clicks go to the notes beneath.
final class GroupRailView: SpringView {
    let edge: ScreenEdge
    private(set) var look: GroupCardView.Look

    /// The strip's width, and the shoulder's height: what the gap between the
    /// header and the first note holds.
    static let width = EdgeMetrics.groupRailWidth
    static let shoulder: CGFloat = 5

    init(look: GroupCardView.Look, edge: ScreenEdge) {
        self.look = look
        self.edge = edge
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(look: GroupCardView.Look) {
        guard self.look != look else { return }
        self.look = look
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Where the rail goes, in the column's coordinates for the right edge:
    /// from the foot of the header (`top`) to the foot of the last note
    /// (`bottom`), starting at the notes' inner side and reaching under the
    /// header's.
    static func frame(top: CGFloat, bottom: CGFloat, columnWidth: CGFloat, outset: CGFloat) -> NSRect {
        let x = columnWidth - EdgeMetrics.tabWidth - outset
        return NSRect(x: x, y: bottom, width: outset + 2, height: max(0, top - bottom))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.height > 0 else { return }
        let bar = Self.width
        let height = bounds.height
        // The shoulder at the top, then the bar down the inner side.
        let radius = bar / 2
        let path = NSBezierPath()
        let shoulderBottom = max(0, height - Self.shoulder)
        path.move(to: NSPoint(x: radius, y: 0))
        path.appendArc(withCenter: NSPoint(x: radius, y: radius), radius: radius, startAngle: 270, endAngle: 180, clockwise: true)
        path.line(to: NSPoint(x: 0, y: height))
        path.line(to: NSPoint(x: bounds.width, y: height))
        path.line(to: NSPoint(x: bounds.width, y: shoulderBottom))
        path.line(to: NSPoint(x: bar, y: shoulderBottom))
        path.line(to: NSPoint(x: bar, y: radius))
        path.appendArc(withCenter: NSPoint(x: radius, y: radius), radius: radius, startAngle: 0, endAngle: 270, clockwise: true)
        path.close()

        let mirror = NSAffineTransform()
        if edge == .left {
            mirror.translateX(by: bounds.width, yBy: 0)
            mirror.scaleX(by: -1, yBy: 1)
        }
        mirror.concat()
        look.fill.setFill()
        path.fill()
        if DisplayOptions.increaseContrast {
            look.ink.withAlphaComponent(0.8).setStroke()
            path.lineWidth = 1
        } else {
            look.sheet(1).withAlphaComponent(0.6).setStroke()
            path.lineWidth = 0.75
        }
        path.stroke()
    }
}
