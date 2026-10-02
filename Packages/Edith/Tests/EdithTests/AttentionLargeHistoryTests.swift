import Foundation
import Testing

@testable import EdithKit

@Suite struct AttentionLargeHistoryTests {
    @Test(.timeLimit(.minutes(1))) func thousandsOfDistinctPagesKeepCompleteTotals() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let count = 12_000
        let events = (0..<count).map { index in
            AttentionEvent(
                startedAt: start.addingTimeInterval(Double(index) * 60), duration: 30,
                source: .browser, appName: "Browser", windowTitle: "Page \(index)",
                url: "https://example.com/page/\(index)", domain: "example.com")
        }
        let summary = AttentionAnalyzer().summary(
            events: events, settings: AttentionSettings(), from: start,
            to: start.addingTimeInterval(30 * 86_400))
        #expect(summary.activeDuration == Double(count) * 30)
        #expect(summary.entities.count == 1)
        #expect(summary.entities.first?.details.count == count)
        #expect(
            summary.dimensions.first { $0.key == AttentionDimension.title }?.rows.count == count)
        #expect(summary.dimensions.first { $0.key == AttentionDimension.url }?.rows.count == count)
    }
}
