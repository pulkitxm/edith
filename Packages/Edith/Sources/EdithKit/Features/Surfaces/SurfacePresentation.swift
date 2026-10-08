import SwiftUI

public struct SurfacePresentation: Equatable, Sendable {
    public var tile: SurfaceTile
    public var padding: Double
    public var cornerRadius: Double

    public init(tile: SurfaceTile, layout: SurfaceLayout) {
        self.tile = tile
        padding = tile.dense ? min(10, layout.padding) : layout.padding
        cornerRadius = layout.cornerRadius
    }
}

extension EnvironmentValues {
    @Entry public var surfacePresentation: SurfacePresentation?
}

public struct SurfaceFittedGrid<Content: View>: View {
    let count: Int
    let minimum: Double
    let gap: Double
    @ViewBuilder let content: () -> Content
    @State private var width = 600.0

    public init(
        count: Int, minimum: Double, gap: Double = 12, @ViewBuilder content: @escaping () -> Content
    ) {
        self.count = count
        self.minimum = minimum
        self.gap = gap
        self.content = content
    }

    public var body: some View {
        let columns = min(
            max(1, count), max(1, Int((width + UIScale.pt(gap)) / UIScale.pt(minimum + gap))))
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(minimum: 0), spacing: UIScale.pt(gap)), count: columns
            ), spacing: UIScale.pt(gap)
        ) {
            content()
        }
        .onGeometryChange(for: Double.self) {
            $0.size.width
        } action: {
            width = $0
        }
    }
}
