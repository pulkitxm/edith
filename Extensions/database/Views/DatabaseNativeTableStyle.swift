import AppKit

enum DatabaseTableMetrics {
    static let rowHeight = 30.0
    static let headerHeight = 28.0
    static let intercellWidth = 12.0
    static let rowColumnWidth = 50.0
    static let rowColumnMinimum = 46.0
    static let rowColumnMaximum = 64.0
    static let columnMinimum = 90.0
    static let columnMaximum = 520.0
    static let indexFont = 10.5
    static let bodyFont = 11.0
    static let headerFont = 11.0
    static let keySide = 11.0

    static func points(_ base: Double, scale: Double) -> CGFloat {
        CGFloat(base * scale)
    }

    static func logical(_ display: CGFloat, scale: Double) -> CGFloat {
        display / CGFloat(max(scale, 0.01))
    }
}

final class DatabaseNativeRowView: NSTableRowView {
    var accentColor = NSColor.controlAccentColor
    var baseColor = NSColor.controlBackgroundColor
    var alternatingColor = NSColor.labelColor.withAlphaComponent(0.025)
    var rowIndex = 0

    override func drawBackground(in dirtyRect: NSRect) {
        baseColor.setFill()
        bounds.fill()
        guard !isSelected else { return }
        if !rowIndex.isMultiple(of: 2) {
            alternatingColor.setFill()
            bounds.fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: 4,
            yRadius: 4
        )
        accentColor.withAlphaComponent(isEmphasized ? 0.2 : 0.11).setFill()
        path.fill()
        accentColor.withAlphaComponent(isEmphasized ? 0.42 : 0.22).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

final class DatabaseNativeHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        NSColor.controlBackgroundColor.setFill()
        cellFrame.fill()
        super.drawInterior(withFrame: cellFrame.insetBy(dx: 8, dy: 3), in: controlView)
        NSColor.separatorColor.withAlphaComponent(0.18).setFill()
        let dividerY = controlView.isFlipped ? cellFrame.maxY - 1 : cellFrame.minY
        NSRect(
            x: cellFrame.minX,
            y: dividerY,
            width: cellFrame.width,
            height: 1
        ).fill()
    }
}
