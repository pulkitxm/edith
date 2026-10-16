import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct BlitzTreeMap: View {
    let report: BlitzTreeReport
    let activate: (BlitzTreeReport.Entry) -> Void

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
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                ForEach(rectangles.indices, id: \.self) { index in
                    let rect = rectangles[index].insetBy(dx: 1, dy: 1)
                    let entry = index < entries.count ? entries[index] : nil
                    if rect.width > 0, rect.height > 0 {
                        Button {
                            if let entry { activate(entry) }
                        } label: {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(entry == nil ? Color.gray.opacity(0.6) : color(index))
                                .overlay(alignment: .topLeading) {
                                    if rect.width > UIScale.pt(58), rect.height > UIScale.pt(38) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(entry?.name ?? "Other")
                                                .font(
                                                    .system(size: UIScale.pt(12), weight: .semibold)
                                                )
                                                .lineLimit(2)
                                            Text(
                                                ByteCountFormatter.string(
                                                    fromByteCount: Int64(
                                                        clamping: entry?.allocatedBytes ?? other),
                                                    countStyle: .file)
                                            )
                                            .font(.system(size: UIScale.pt(10)))
                                        }
                                        .foregroundStyle(.white)
                                        .padding(8)
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

    private func color(_ index: Int) -> Color {
        [.blue, .teal, .indigo, .orange, .purple, .green][index % 6]
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
