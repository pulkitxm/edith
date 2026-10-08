import EdithKit
import Foundation
import Testing

@testable import Edith

@Suite struct AttentionBreakdownProjectionTests {
    @Test func largeReportsKeepEveryGroupAndSearchTheEntireReport() {
        var summary = AttentionSummary(from: .distantPast, to: Date())
        summary.dimensions = [
            AttentionDimension(
                key: AttentionDimension.title,
                rows: (0..<10_000).map { index in
                    AttentionBreakdownRow(
                        key: "Sample page \(index)", duration: Double(index + 1),
                        categories: ["focus": Double(index + 1)], interactions: index,
                        entityNames: ["Sample browser"], levels: ["productive": Double(index + 1)])
                }, total: 50_005_000)
        ]
        let filter = AttentionSpanFilter(search: "")
        let projection = AttentionBreakdownProjection(
            summary: summary,
            dimension: AttentionDimension.title, filter: filter, sort: .time)
        #expect(projection.rows.count == 10_000)
        #expect(projection.rows.first?.label == "Sample page 9999")
        #expect(projection.top.count == 8)
        #expect(projection.total == 50_005_000)
        let searched = AttentionBreakdownProjection(
            summary: summary,
            dimension: AttentionDimension.title, filter: AttentionSpanFilter(search: "9999"),
            sort: .name)
        #expect(searched.rows.map(\.label) == ["Sample page 9999"])
        #expect(searched.total == 10_000)
        let excluded = AttentionBreakdownProjection(
            summary: summary,
            dimension: AttentionDimension.title,
            filter: AttentionSpanFilter(category: "other", search: ""), sort: .inputs)
        #expect(excluded.rows.isEmpty)
        #expect(excluded.total == 0)
    }
}
