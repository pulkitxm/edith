import AppKit
import EdithKit
import Testing
@testable import EdithHelper

@MainActor
@Suite struct LimitsStatusItemTests {
    @Test func menuBarProvidersKeepEveryEnabledSlotReserved() {
        let suite = "menu-bar-provider-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppStorageKeys.Limits.claudeEnabled)
        defaults.set(true, forKey: AppStorageKeys.Limits.codexEnabled)
        let codex = ProviderLimits(
            provider: .codex, session: LimitWindow(percent: 42, resetsAt: nil), week: nil)

        let providers = LimitsStatusItem.stableProviders([codex], defaults: defaults)

        #expect(providers.map(\.provider) == [.claude, .codex])
        #expect(providers[0].isAvailable == false)
        #expect(providers[1].session?.percent == 42)
    }

    @Test func sizingGroupsReserveThreeDigitPercentages() {
        let groups = [
            MenuBarProviderGroup(
                provider: .claude,
                segments: [
                    MenuBarLimitSegment(slot: .session, value: .missing, window: nil),
                    MenuBarLimitSegment(slot: .week, value: .percent(9), window: nil),
                    MenuBarLimitSegment(slot: .fable, value: .masked, window: nil),
                ])
        ]

        let sizing = LimitsStatusItem.sizingGroups(groups)

        #expect(sizing[0].segments.map(\.value) == [.percent(100), .percent(100), .percent(100)])
    }

    @Test func titleSizingIncludesStatusButtonInsets() {
        let title = NSAttributedString(
            string: "100%  100%",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)])

        #expect(StatusItemSizing.titleLength(title) > ceil(title.size().width))
    }

    @Test func retiredStatusItemsCannotKeepMenuBarItemsDisabled() {
        let suite = "limits-status-item-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "NSStatusItem VisibleCC edithGlasses")
        defaults.set(42, forKey: "NSStatusItem Preferred Position edithGlasses")
        defaults.set(false, forKey: "NSStatusItem VisibleCC limits")
        defaults.set(false, forKey: "NSStatusItem VisibleCC systemStats")

        removeRetiredStatusItemDefaults(defaults)

        #expect(defaults.object(forKey: "NSStatusItem VisibleCC edithGlasses") == nil)
        #expect(defaults.object(forKey: "NSStatusItem Preferred Position edithGlasses") == nil)
        #expect(defaults.object(forKey: "NSStatusItem VisibleCC limits") == nil)
        #expect(defaults.object(forKey: "NSStatusItem VisibleCC systemStats") == nil)
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
