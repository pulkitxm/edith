import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Testing
@testable import UsageExtension

@MainActor
@Suite struct LimitsStatusItemTests {
    @Test func resetCountdownFormatsEveryUnitAndRollover() {
        let now = Date(timeIntervalSince1970: 0)
        let cases: [(TimeInterval, String)] = [
            (-1, "0s"), (0, "0s"), (0.1, "1s"), (9, "9s"), (59, "59s"),
            (60, "1m 0s"), (3599, "59m 59s"), (3600, "1h 0m 0s"),
            (86399, "23h 59m 59s"), (86400, "1d 0h 0m 0s"),
            (183845, "2d 3h 4m 5s"),
        ]
        for (interval, expected) in cases {
            #expect(
                MenuCountdown.remaining(until: now.addingTimeInterval(interval), now: now)
                    == expected)
        }
    }

    @Test func menuBarProvidersKeepEveryEnabledSlotReserved() {
        let suite = "menu-bar-provider-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppStorageKeys.Limits.claudeEnabled)
        defaults.set(true, forKey: AppStorageKeys.Limits.codexEnabled)
        let codex = ProviderLimits(
            provider: .codex, session: LimitWindow(percent: 42, resetsAt: nil), week: nil)

        let providers = LimitsStatusItem.stableProviders([codex], defaults: defaults)

        #expect(providers.map(\.provider) == [.claude, .codex, .cursor, .grok])
        #expect(providers[0].isAvailable == false)
        #expect(providers[1].session?.percent == 42)
    }

    @Test func stackedLayoutUsesCurrentValueWidths() {
        let compact = StackedLimitsView()
        compact.groups = [
            .init(
                logo: nil,
                columns: [
                    .init(
                        label: "5h", value: "7", valueColor: .labelColor, labelColor: .labelColor),
                    .init(
                        label: "7d", value: "53", valueColor: .labelColor, labelColor: .labelColor),
                    .init(
                        label: "F", value: "54", valueColor: .labelColor, labelColor: .labelColor),
                ])
        ]
        let maximum = StackedLimitsView()
        maximum.groups = [
            .init(
                logo: nil,
                columns: [
                    .init(
                        label: "5h", value: "100", valueColor: .labelColor, labelColor: .labelColor),
                    .init(
                        label: "7d", value: "100", valueColor: .labelColor, labelColor: .labelColor),
                    .init(
                        label: "F", value: "100", valueColor: .labelColor, labelColor: .labelColor),
                ])
        ]

        #expect(compact.desiredWidth < maximum.desiredWidth)
    }

    @Test func titleSizingIncludesStatusButtonInsets() {
        let title = NSAttributedString(
            string: "100%  100%",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)])

        #expect(StatusItemSizing.titleLength(title) == ceil(title.size().width + 8))
    }

    @Test func legacyFixedTintsBecomeAutomatic() {
        #expect(MenuBarTintMode(preference: nil) == .automatic)
        #expect(MenuBarTintMode(preference: "auto") == .automatic)
        #expect(MenuBarTintMode(preference: "white") == .automatic)
        #expect(MenuBarTintMode(preference: "black") == .automatic)
        #expect(MenuBarTintMode(preference: "custom") == .custom)
        #expect(MenuBarTintMode.automatic.color(custom: .white) == .labelColor)
        #expect(MenuBarTintMode.custom.color(custom: .systemPink) == .systemPink)
        #expect(MenuBarTintMode.custom.color(custom: nil) == .labelColor)
    }

    @Test func lowRiskIsPureGreen() {
        #expect(LimitsStatusItem.color(forRisk: 0.0) == .systemGreen)
        #expect(LimitsStatusItem.color(forRisk: 0.30) == .systemGreen)
    }

    @Test func highRiskIsPureRed() {
        #expect(LimitsStatusItem.color(forRisk: 0.85) == .systemRed)
        #expect(LimitsStatusItem.color(forRisk: 1.0) == .systemRed)
    }

    @Test func midRiskIsInterpolated() {
        let c = LimitsStatusItem.color(forRisk: 0.42)
        #expect(c != .systemGreen)
        #expect(c != .systemRed)
    }

    @Test func riskClamps() {
        #expect(LimitsStatusItem.color(forRisk: -1) == .systemGreen)
        #expect(LimitsStatusItem.color(forRisk: 2) == .systemRed)
    }
}
