import SwiftUI

public struct SurfaceGlanceLabel: View {
    public var glance: SurfaceGlance
    public init(_ glance: SurfaceGlance) { self.glance = glance }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: UIScale.pt(5)) {
                Image(systemName: glance.icon).font(.edithText(.caption2))
                value
            }.fixedSize(horizontal: true, vertical: false)
            value
        }
    }

    private var value: some View {
        Text(glance.value).font(.edithText(.caption)).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.7)
    }
}
