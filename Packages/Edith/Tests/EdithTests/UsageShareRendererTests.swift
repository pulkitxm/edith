import AppKit
import EdithKit
import Testing

@Suite struct UsageShareRendererTests {
    private let snapshot = UsageShareSnapshot(
        days: [
            UsageShareDay(period: "2026-08-20", tokens: 1_000, cost: 1),
            UsageShareDay(period: "2026-08-21", tokens: 2_000, cost: 2),
            UsageShareDay(period: "2026-08-22", tokens: 0, cost: 0),
            UsageShareDay(period: "2026-08-23", tokens: 8_000, cost: 3),
        ],
        agentCount: 3, repositoryCount: 4, generatedAt: "2026-08-23T12:00:00Z")

    @Test func snapshotDerivesShareableMilestones() {
        #expect(snapshot.totalTokens == 11_000)
        #expect(snapshot.activeDays == 3)
        #expect(snapshot.longestStreak == 2)
        #expect(snapshot.busiestDay?.period == "2026-08-23")
        #expect(snapshot.averageTokensPerActiveDay == 11_000.0 / 3)
    }

    @Test @MainActor func everyCardRendersAsAHighResolutionPNG() throws {
        for card in UsageShareCard.allCases {
            let data = try UsageShareRenderer.pngData(snapshot: snapshot, card: card, scale: 1)
            let image = try #require(NSImage(data: data))
            let bitmap = try #require(NSBitmapImageRep(data: data))
            #expect(image.size == UsageShareRenderer.size)
            #expect(data.count > 20_000)
            #expect(bitmap.colorAt(x: 0, y: 0)?.alphaComponent == 1)
            #expect(
                bitmap.colorAt(x: bitmap.pixelsWide - 1, y: bitmap.pixelsHigh - 1)?.alphaComponent
                    == 1)
            if let outputDirectory = ProcessInfo.processInfo.environment[
                "EDITH_USAGE_SHARE_EVIDENCE_DIR"
            ] {
                let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent(card.filenameStem + ".png"))
            }
        }
    }

    @Test func filenamesCarryTheEdithBrand() {
        #expect(UsageShareCard.activity.filenameStem == "edith-usage-activity")
        #expect(UsageShareCard.allCases.map(\.id).count == 4)
    }
}
