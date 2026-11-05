import EdithExtensionUI
import SwiftUI

enum SocialTileRows {
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

struct SocialTileGrid<Item: Identifiable, Tile: View>: View {
    let items: [Item]
    @ViewBuilder let tile: (Item) -> Tile
    @Environment(\.compactLayout) private var compact
    @State private var width: CGFloat = 0

    var body: some View {
        let gap = UIScale.pt(12)
        let rows = SocialTileRows.rows(
            count: items.count, available: width, minimum: UIScale.pt(250), spacing: gap,
            maximumColumns: compact ? 1 : .max)
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
