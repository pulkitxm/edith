import SwiftUI

public struct ArchedNiche: InsettableShape {
    var topRadius: CGFloat?
    var insetAmount: CGFloat = 0

    public init(topRadius: CGFloat? = nil) {
        self.topRadius = topRadius
    }

    public func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let r = min(topRadius ?? rect.width / 2, rect.width / 2, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.minY + r),
            radius: r,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: true)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    public func inset(by amount: CGFloat) -> ArchedNiche {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}
