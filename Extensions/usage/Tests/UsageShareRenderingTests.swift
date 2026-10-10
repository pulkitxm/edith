import AppKit
import Foundation
import Testing
@testable import UsageExtension

@MainActor
extension UsageDashboardRenderingTests {
    private var sharedFixture: UsageShareSnapshot {
        .init(
            days: [
                .init(period: "2026-10-07", tokens: 1_000, cost: 1),
                .init(period: "2026-10-08", tokens: 2_000, cost: 2),
                .init(period: "2026-10-09", tokens: 8_000, cost: 3),
            ], agentCount: 3, repositoryCount: 4)
    }

    @Test func shareSnapshotDerivesMilestonesFromSyntheticUsage() {
        let snapshot = sharedFixture
        #expect(snapshot.totalTokens == 11_000)
        #expect(snapshot.activeDays == 3)
        #expect(snapshot.longestStreak == 3)
        #expect(snapshot.busiestDay?.period == "2026-10-09")
    }

    @Test func everyOriginalShareCardRendersItsArtworkAsOpaquePNG() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        for card in UsageShareCard.allCases {
            let data = try UsageShareRenderer.pngData(snapshot: sharedFixture, card: card, scale: 1)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            #expect(bitmap.pixelsWide == 1_200 && bitmap.pixelsHigh == 800)
            #expect(data.count > 20_000)
            #expect(bitmap.colorAt(x: 0, y: 0)?.alphaComponent == 1)
            #expect(bitmap.colorAt(x: 1_199, y: 799)?.alphaComponent == 1)
        }
    }
}
