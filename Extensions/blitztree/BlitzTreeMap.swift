import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

enum BlitzTreePalette {
    private static let steps: [(contrast: Double, hue: CGFloat)] = [
        (4.6, 0), (6.4, -0.012), (5.4, 0.012), (8.2, 0), (4.9, -0.02), (7.2, 0.02),
    ]

    static func tones(theme: AppTheme, dark: Bool) -> [NSColor] {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        let base = NSColor(theme.accent(dark: dark)).usingColorSpace(.sRGB) ?? .systemGray
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return steps.map { step in
            func tone(_ brightness: CGFloat) -> NSColor {
                NSColor(
                    hue: (hue + step.hue + 1).truncatingRemainder(dividingBy: 1),
                    saturation: max(saturation, 0.55), brightness: brightness, alpha: 1
                ).usingColorSpace(.sRGB) ?? base
            }
            var low: CGFloat = 0
            var high: CGFloat = 1
            for _ in 0..<12 {
                let middle = (low + high) / 2
                if contrast(.white, tone(middle)) >= step.contrast {
                    low = middle
                } else {
                    high = middle
                }
            }
            return tone(low)
        }
    }

    static func luminance(_ color: NSColor) -> Double {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        func linear(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(srgb.redComponent) + 0.7152 * linear(srgb.greenComponent)
            + 0.0722 * linear(srgb.blueComponent)
    }

    static func contrast(_ first: NSColor, _ second: NSColor) -> Double {
        let values = [luminance(first), luminance(second)]
        return ((values.max() ?? 0) + 0.05) / ((values.min() ?? 0) + 0.05)
    }
}

struct BlitzTreeMap: View {
    let report: BlitzTreeReport
    let activate: (BlitzTreeReport.Entry) -> Void
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        AppTheme.standard.rawValue
    @Environment(\.colorScheme) private var scheme

    private var entries: [BlitzTreeReport.Entry] {
        Array(report.report.inventory.largestChildren.filter { $0.allocatedBytes > 0 }.prefix(60))
    }

    var body: some View {
        GeometryReader { proxy in
            let entries = entries
            let other = entries.reduce(report.summary.allocatedBytes) {
                $0 - min($0, $1.allocatedBytes)
            }
            let weights =
                entries.map { Double($0.allocatedBytes) } + (other > 0 ? [Double(other)] : [])
            let rectangles = BlitzTreeLayout.rectangles(
                weights: weights, in: CGRect(origin: .zero, size: proxy.size))
            let tones = BlitzTreePalette.tones(
                theme: AppTheme(storedName: themeName), dark: scheme == .dark)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: UIScale.pt(PageMetrics.chipCornerRadius))
                    .fill(.quaternary)
                ForEach(rectangles.indices, id: \.self) { index in
                    let rect = rectangles[index].insetBy(dx: 1, dy: 1)
                    let entry = index < entries.count ? entries[index] : nil
                    if rect.width > 0, rect.height > 0 {
                        Button {
                            if let entry { activate(entry) }
                        } label: {
                            RoundedRectangle(cornerRadius: UIScale.pt(4))
                                .fill(
                                    entry == nil
                                        ? AnyShapeStyle(.quaternary)
                                        : AnyShapeStyle(Color(nsColor: tones[index % tones.count]))
                                )
                                .overlay(alignment: .topLeading) {
                                    if rect.width > UIScale.pt(58), rect.height > UIScale.pt(38) {
                                        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                                            Text(entry?.name ?? "Other")
                                                .font(.edithText(.callout)).fontWeight(.semibold)
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                            Text(
                                                ByteCountFormatter.string(
                                                    fromByteCount: Int64(
                                                        clamping: entry?.allocatedBytes ?? other),
                                                    countStyle: .file)
                                            )
                                            .font(.edithText(.caption)).monospacedDigit()
                                        }
                                        .foregroundStyle(entry == nil ? Color.primary : Color.white)
                                        .padding(UIScale.pt(8))
                                    }
                                }
                                .clipped()
                        }
                        .buttonStyle(.edith(.borderless))
                        .disabled(entry == nil)
                        .accessibilityLabel(entry?.name ?? "Other unlisted space")
                        .help(entry?.path ?? "Unlisted entries and folder metadata")
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                    }
                }
                if weights.isEmpty {
                    Text("No allocated space in this folder")
                        .foregroundStyle(.secondary)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
    }
}

enum BlitzTreeLayout {
    static func rectangles(weights: [Double], in bounds: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: weights.count)
        let valid = weights.indices.filter { weights[$0].isFinite && weights[$0] > 0 }
        func partition(_ indices: ArraySlice<Int>, _ rect: CGRect) {
            guard let first = indices.first else { return }
            guard indices.count > 1 else {
                result[first] = rect
                return
            }
            let total = indices.reduce(0) { $0 + weights[$1] }
            var leftWeight = 0.0
            var count = 0
            for index in indices.dropLast() {
                leftWeight += weights[index]
                count += 1
                if leftWeight >= total / 2 { break }
            }
            let fraction = leftWeight / total
            let horizontal = rect.width >= rect.height
            let distance = (horizontal ? rect.width : rect.height) * fraction
            let parts = rect.divided(atDistance: distance, from: horizontal ? .minXEdge : .minYEdge)
            partition(indices.prefix(count), parts.slice)
            partition(indices.dropFirst(count), parts.remainder)
        }
        if bounds.width > 0, bounds.height > 0 { partition(valid[...], bounds) }
        return result
    }
}
