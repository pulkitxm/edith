import AppKit

enum FileIconRenderer {
    static let size = NSSize(width: 64, height: 64)

    static func image(for descriptor: FileIconDescriptor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSGraphicsContext.current?.imageInterpolation = .high
        drawDocument(descriptor)
        drawSymbol(descriptor)
        drawBadge(descriptor)
        image.isTemplate = false
        return image
    }

    private static func drawDocument(_ descriptor: FileIconDescriptor) {
        let accent = color(descriptor.color)
        let shape = NSBezierPath()
        shape.move(to: NSPoint(x: 10, y: 3))
        shape.line(to: NSPoint(x: 43, y: 3))
        shape.line(to: NSPoint(x: 55, y: 15))
        shape.line(to: NSPoint(x: 55, y: 58))
        shape.curve(
            to: NSPoint(x: 51, y: 62), controlPoint1: NSPoint(x: 55, y: 60.2),
            controlPoint2: NSPoint(x: 53.2, y: 62))
        shape.line(to: NSPoint(x: 10, y: 62))
        shape.curve(
            to: NSPoint(x: 6, y: 58), controlPoint1: NSPoint(x: 7.8, y: 62),
            controlPoint2: NSPoint(x: 6, y: 60.2))
        shape.line(to: NSPoint(x: 6, y: 7))
        shape.curve(
            to: NSPoint(x: 10, y: 3), controlPoint1: NSPoint(x: 6, y: 4.8),
            controlPoint2: NSPoint(x: 7.8, y: 3))
        shape.close()

        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
        shape.fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        accent.withAlphaComponent(0.72).setStroke()
        shape.lineWidth = 1.4
        shape.stroke()

        let wash = NSBezierPath(roundedRect: NSRect(x: 9, y: 7, width: 43, height: 50), xRadius: 2, yRadius: 2)
        accent.withAlphaComponent(0.08).setFill()
        wash.fill()

        let fold = NSBezierPath()
        fold.move(to: NSPoint(x: 43, y: 61))
        fold.line(to: NSPoint(x: 43, y: 49))
        fold.curve(
            to: NSPoint(x: 47, y: 45), controlPoint1: NSPoint(x: 43, y: 46.8),
            controlPoint2: NSPoint(x: 44.8, y: 45))
        fold.line(to: NSPoint(x: 55, y: 45))
        fold.close()
        accent.withAlphaComponent(0.18).setFill()
        fold.fill()
        accent.withAlphaComponent(0.55).setStroke()
        fold.lineWidth = 1.1
        fold.stroke()
    }

    private static func drawSymbol(_ descriptor: FileIconDescriptor) {
        let accent = color(descriptor.color)
        let base = NSImage(systemSymbolName: descriptor.symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "doc.fill", accessibilityDescription: nil)
        guard let base else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: accent))
        let symbol = base.withSymbolConfiguration(configuration) ?? base
        let target = NSRect(x: 18, y: 30, width: 24, height: 21)
        symbol.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
    }

    private static func drawBadge(_ descriptor: FileIconDescriptor) {
        let accent = color(descriptor.color)
        let badge = NSBezierPath(roundedRect: NSRect(x: 10, y: 8, width: 41, height: 17), xRadius: 5, yRadius: 5)
        accent.setFill()
        badge.fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let fontSize: CGFloat = descriptor.badge.count > 3 ? 8.5 : 10
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: labelColor(descriptor.color),
            .paragraphStyle: paragraph,
        ]
        let text = NSAttributedString(string: descriptor.badge, attributes: attributes)
        text.draw(in: NSRect(x: 11, y: 10.5, width: 39, height: 12))
    }

    private static func color(_ color: FileIconColor) -> NSColor {
        switch color {
        case .amber: NSColor(srgbRed: 0.96, green: 0.64, blue: 0.08, alpha: 1)
        case .blue: NSColor(srgbRed: 0.13, green: 0.45, blue: 0.86, alpha: 1)
        case .brown: NSColor(srgbRed: 0.56, green: 0.34, blue: 0.2, alpha: 1)
        case .cyan: NSColor(srgbRed: 0.05, green: 0.65, blue: 0.78, alpha: 1)
        case .gray: NSColor(srgbRed: 0.39, green: 0.43, blue: 0.49, alpha: 1)
        case .green: NSColor(srgbRed: 0.16, green: 0.62, blue: 0.34, alpha: 1)
        case .indigo: NSColor(srgbRed: 0.31, green: 0.32, blue: 0.73, alpha: 1)
        case .orange: NSColor(srgbRed: 0.94, green: 0.39, blue: 0.12, alpha: 1)
        case .pink: NSColor(srgbRed: 0.86, green: 0.24, blue: 0.52, alpha: 1)
        case .purple: NSColor(srgbRed: 0.55, green: 0.29, blue: 0.78, alpha: 1)
        case .red: NSColor(srgbRed: 0.84, green: 0.22, blue: 0.2, alpha: 1)
        case .teal: NSColor(srgbRed: 0.08, green: 0.58, blue: 0.55, alpha: 1)
        case .yellow: NSColor(srgbRed: 0.94, green: 0.76, blue: 0.08, alpha: 1)
        }
    }

    private static func labelColor(_ color: FileIconColor) -> NSColor {
        switch color {
        case .amber, .cyan, .yellow: NSColor(srgbRed: 0.08, green: 0.1, blue: 0.13, alpha: 1)
        default: .white
        }
    }
}
