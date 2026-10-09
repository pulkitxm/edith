import EdithExtensionSupport
import SwiftUI

public struct SurfacePresentation: Equatable, Sendable {
    public var tile: SurfaceTile
    public var padding: Double
    public var cornerRadius: Double

    public init(tile: SurfaceTile, layout: SurfaceLayout) {
        self.tile = tile
        padding = tile.paddingOverride ?? (tile.dense ? min(10, layout.padding) : layout.padding)
        cornerRadius = tile.cornerOverride ?? layout.cornerRadius
    }
}

extension SurfaceTile {
    public var highlightColor: Color {
        guard accent else { return .secondary }
        guard let accentHex, accentHex.utf8.count == 6, let value = UInt32(accentHex, radix: 16)
        else {
            return themeColor(
                SharedDefaults.store.string(forKey: AppStorageKeys.General.theme) ?? "accent")
        }
        return Color(
            red: Double((value >> 16) & 255) / 255,
            green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    public func metricGrid(minimum: Double, spacing: Double = 12) -> [GridItem] {
        if let metricColumns {
            return Array(
                repeating: GridItem(.flexible(minimum: 0), spacing: UIScale.pt(spacing)),
                count: min(6, max(1, metricColumns)))
        }
        return [GridItem(.adaptive(minimum: UIScale.pt(minimum)), spacing: UIScale.pt(spacing))]
    }
}

extension EnvironmentValues {
    @Entry public var surfacePresentation: SurfacePresentation?
    @Entry public var surfaceSampleContent = false
    @Entry public var surfaceFillHeight = false
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
