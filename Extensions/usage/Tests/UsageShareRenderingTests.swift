import AppKit
import EdithExtensionSupport
import EdithExtensionUI
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
        for card in UsageShareCard.allCases {
            let data = try UsageShareRenderer.pngData(snapshot: sharedFixture, card: card, scale: 1)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            #expect(bitmap.pixelsWide == 1_200 && bitmap.pixelsHigh == 800)
            #expect(data.count > 20_000)
            #expect(bitmap.colorAt(x: 0, y: 0)?.alphaComponent == 1)
            #expect(bitmap.colorAt(x: 1_199, y: 799)?.alphaComponent == 1)
        }
    }

    private func apricotPixels(theme: AppTheme) async throws -> Int {
        let defaults = ExtensionScope.process.defaults()
        defaults.set(theme.rawValue, forKey: AppStorageKeys.General.theme)
        try await Task.sleep(for: .milliseconds(120))
        var count = 0
        for card in UsageShareCard.allCases {
            let data = try UsageShareRenderer.pngData(snapshot: sharedFixture, card: card, scale: 1)
            if let path = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"] {
                try data.write(
                    to: URL(fileURLWithPath: path).appendingPathComponent(
                        "usage-share-\(theme.rawValue)-\(card.rawValue).png"))
            }
            let bitmap = try #require(NSBitmapImageRep(data: data))
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                        continue
                    }
                    let warm = color.hueComponent < 0.11 || color.hueComponent > 0.97
                    if warm && color.saturationComponent > 0.3 && color.brightnessComponent > 0.6 {
                        count += 1
                    }
                }
            }
        }
        return count
    }

    @Test func shareCardsFollowTheSelectedThemeInsteadOfTheHouseApricot() async throws {
        let defaults = ExtensionScope.process.defaults()
        let prior = defaults.string(forKey: AppStorageKeys.General.theme)
        defer { defaults.set(prior, forKey: AppStorageKeys.General.theme) }
        let house = try await apricotPixels(theme: .accent)
        let themed = try await apricotPixels(theme: .teal)
        #expect(house > 200)
        #expect(themed * 8 < house)
    }

    @Test func thePrimaryChartSeriesFollowsTheSelectedTheme() async throws {
        let defaults = ExtensionScope.process.defaults()
        let prior = defaults.string(forKey: AppStorageKeys.General.theme)
        defer { defaults.set(prior, forKey: AppStorageKeys.General.theme) }
        defaults.set(AppTheme.green.rawValue, forKey: AppStorageKeys.General.theme)
        try await Task.sleep(for: .milliseconds(120))
        for dark in [false, true] {
            #expect(DashPalette.categorical(0, dark: dark) == DashSkin.accent(dark))
            #expect(DashPalette.outputColor(dark) == DashSkin.accent(dark))
            #expect(DashPalette.modelColor(0, dark: dark) == DashSkin.accent(dark))
        }
    }
}
