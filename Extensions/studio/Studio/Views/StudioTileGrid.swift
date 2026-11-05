import EdithExtensionUI
import SwiftUI

enum StudioLayoutMetrics {
    static let workspaceInset = 16.0
    static let toolbarInset = 6.0
}

enum StudioTileRows {
    static func rows(
        count: Int, available: CGFloat, minimum: CGFloat, spacing: CGFloat,
        maximumColumns: Int = .max
    ) -> [Range<Int>] {
        guard count > 0 else { return [] }
        let fit = available > 0 ? Int((available + spacing) / (minimum + spacing)) : 1
        let columns = min(count, maximumColumns, max(1, fit))
        let smallestEven = max(1, (columns + 1) * 2 / 3)
        let perRow =
            stride(from: columns, through: smallestEven, by: -1)
            .first { count.isMultiple(of: $0) } ?? columns
        let rowCount = (count + perRow - 1) / perRow
        let shortRow = count / rowCount
        let longRows = count % rowCount
        var start = 0
        return (0..<rowCount).map { index in
            let end = start + shortRow + (index < longRows ? 1 : 0)
            defer { start = end }
            return start..<end
        }
    }
}

struct StudioTileGrid<Item: Identifiable, Tile: View>: View {
    let items: [Item]
    var minimum = 240.0
    var spacing = 12.0
    var maximumColumns = Int.max
    @ViewBuilder let tile: (Item) -> Tile
    @State private var width: CGFloat = 0

    var body: some View {
        let gap = UIScale.pt(spacing)
        let rows = StudioTileRows.rows(
            count: items.count, available: width, minimum: UIScale.pt(minimum), spacing: gap,
            maximumColumns: maximumColumns)
        LazyVStack(spacing: gap) {
            ForEach(rows, id: \.lowerBound) { row in
                HStack(alignment: .top, spacing: gap) {
                    ForEach(items[row]) { item in
                        tile(item).frame(
                            minWidth: 0, idealWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            width = $0
        }
    }
}

struct StudioListSurface<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0, content: content)
            .frame(maxWidth: .infinity)
            .background(
                DashSkin.paper2(scheme == .dark),
                in: RoundedRectangle(cornerRadius: UIScale.pt(12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIScale.pt(12)).strokeBorder(
                    DashSkin.line(scheme == .dark)))
    }
}
