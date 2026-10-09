import CoreGraphics
import EdithStudio
import PDFKit

struct StudioPDFGrip: Equatable, Sendable {
    var left = false
    var right = false
    var bottom = false
    var top = false

    static let move = StudioPDFGrip()

    static let handles: [StudioPDFGrip] = [
        StudioPDFGrip(left: true, bottom: true), StudioPDFGrip(bottom: true),
        StudioPDFGrip(right: true, bottom: true), StudioPDFGrip(right: true),
        StudioPDFGrip(right: true, top: true), StudioPDFGrip(top: true),
        StudioPDFGrip(left: true, top: true), StudioPDFGrip(left: true),
    ]

    static let minimumSide: CGFloat = 4

    var isMove: Bool { !left && !right && !bottom && !top }

    func anchor(in rect: CGRect) -> CGPoint {
        CGPoint(
            x: left ? rect.minX : right ? rect.maxX : rect.midX,
            y: bottom ? rect.minY : top ? rect.maxY : rect.midY)
    }

    func apply(to rect: CGRect, delta: CGPoint) -> CGRect {
        let rect = rect.standardized
        guard !isMove else { return rect.offsetBy(dx: delta.x, dy: delta.y) }
        let side = Self.minimumSide
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY
        if left { minX = min(minX + delta.x, maxX - side) }
        if right { maxX = max(maxX + delta.x, minX + side) }
        if bottom { minY = min(minY + delta.y, maxY - side) }
        if top { maxY = max(maxY + delta.y, minY + side) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func resizable(_ annotation: PDFAnnotation) -> Bool {
        ["Square", "Circle", "FreeText", "Stamp", "Widget"].contains(annotation.type ?? "")
    }

    static func isRedaction(_ annotation: PDFAnnotation) -> Bool {
        annotation.userName == PDFEditSession.redactionMarker
    }

    static func nudge(_ direction: CGPoint, by amount: CGFloat) -> CGPoint {
        let length = hypot(direction.x, direction.y)
        guard length > 0 else { return .zero }
        return CGPoint(x: direction.x / length * amount, y: direction.y / length * amount)
    }
}
