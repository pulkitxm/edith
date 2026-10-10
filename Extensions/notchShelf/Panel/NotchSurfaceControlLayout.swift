import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct SurfaceControlLayout: Layout {
    var minimumWidth: Double
    var cellHeight: Double
    var gap: Double

    init(minimumWidth: Double = 120, cellHeight: Double = 80, gap: Double = 8) {
        self.minimumWidth = minimumWidth; self.cellHeight = cellHeight; self.gap = gap
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ())
        -> CGSize
    {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? UIScale.pt(400)
        let rows = SurfaceArrangement.rowCounts(
            count: subviews.count,
            width: Double(width / UIScale.current), minimumWidth: minimumWidth,
            maximumColumns: subviews.count, gap: gap)
        let height = UIScale.pt(
            Double(rows.count) * cellHeight + Double(max(0, rows.count - 1)) * gap)
        return CGSize(
            width: width, height: proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? height)
    }
    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout ()
    ) {
        let rows = SurfaceArrangement.rowCounts(
            count: subviews.count,
            width: Double(bounds.width / UIScale.current), minimumWidth: minimumWidth,
            maximumColumns: subviews.count, gap: gap)
        guard !rows.isEmpty else { return }
        let gap = UIScale.pt(gap)
        let height = max(1, (bounds.height - CGFloat(rows.count - 1) * gap) / CGFloat(rows.count))
        var index = 0
        for (row, count) in rows.enumerated() {
            let width = max(1, (bounds.width - CGFloat(count - 1) * gap) / CGFloat(count))
            for column in 0..<count {
                subviews[index].place(
                    at: CGPoint(
                        x: bounds.minX + CGFloat(column) * (width + gap),
                        y: bounds.minY + CGFloat(row) * (height + gap)), anchor: .topLeading,
                    proposal: ProposedViewSize(width: width, height: height))
                index += 1
            }
        }
    }
}
