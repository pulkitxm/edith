import EdithExtensionSupport
import Foundation
import Testing

@testable import UsageExtension

@Suite struct MenuBarLimitsTests {
    let now = Date(timeIntervalSince1970: 1_787_000_000)

    @Test func missingSelectionShowsEveryWindow() {
        #expect(
            MenuBarLimits.parseSelection(nil, provider: .claude) == [.session, .week, .fable])
        #expect(MenuBarLimits.parseSelection(nil, provider: .codex) == [.session, .week])
        #expect(MenuBarLimits.parseSelection(nil, provider: .cursor) == [.session, .week])
        #expect(MenuBarLimits.parseSelection(nil, provider: .grok) == [.week])
        #expect(LimitWindowSlot.week.menuBarLabel(for: .grok, period: "monthly") == "Mo")
        #expect(LimitWindowSlot.week.menuBarLabel(for: .grok, period: "weekly") == "Wk")
        #expect(LimitWindowSlot.week.settingsLabel(for: .grok) == "Allowance")
        #expect(LimitWindowSlot.week.title(for: .grok, period: "daily") == "Daily allowance")
        #expect(LimitWindowSlot.week.pacingDuration(for: .grok, period: "daily") == 24 * 3600)
        #expect(LimitWindowSlot.session.menuBarLabel(for: .cursor) == "CM")
        #expect(LimitWindowSlot.week.menuBarLabel(for: .cursor) == "OM")
        #expect(LimitWindowSlot.session.settingsLabel(for: .cursor) == "Cursor models")
        #expect(LimitWindowSlot.week.settingsLabel(for: .cursor) == "Other models")
        #expect(LimitWindowSlot.session.title(for: .cursor) == "Cursor models")
        #expect(LimitWindowSlot.week.title(for: .cursor) == "Other models")
    }

    @Test func codexCreditsAreAnOptInMenuBarSegment() {
        #expect(MenuBarLimits.menuBarSlots(for: .codex) == [.session, .week, .credits])
        #expect(MenuBarLimits.menuBarSlots(for: .claude) == [.session, .week, .fable])
        #expect(
            MenuBarLimits.parseSelection("credits,week", provider: .codex) == [.week, .credits])
        #expect(MenuBarLimits.parseSelection("credits", provider: .claude).isEmpty)
        #expect(!LimitAlertTarget.all.contains { $0.slot == .credits })
        let codex = ProviderLimits(
            provider: .codex, session: nil, week: LimitWindow(percent: 34, resetsAt: nil),
            credits: 7071.418)
        let groups = MenuBarLimits.groups(
            providers: [codex], selection: { _ in [.week, .credits] }, masked: false)
        #expect(groups[0].segments.map(\.value) == [.percent(34), .credits(7071.418)])
        let empty = MenuBarLimits.groups(
            providers: [ProviderLimits(provider: .codex, session: nil, week: nil)],
            selection: { _ in [.credits] }, masked: false)
        #expect(empty[0].segments.map(\.value) == [.missing])
        #expect(LimitWindowSlot.credits.menuBarLabel(for: .codex) == "CR")
        #expect(MenuBarLimits.creditsBalance(7071.918) == "7071")
        #expect(MenuBarLimits.creditsBalance(12_345_678.5) == "12345678")
        #expect(MenuBarLimits.creditsBalance(0.4) == "0")
    }

    @Test func selectionKeepsCanonicalOrderAndDropsGarbage() {
        let parsed = MenuBarLimits.parseSelection("fable , session,nope", provider: .claude)
        #expect(parsed == [.session, .fable])
        #expect(MenuBarLimits.parseSelection("fable", provider: .codex).isEmpty)
        #expect(MenuBarLimits.parseSelection("", provider: .claude).isEmpty)
    }

    @Test func selectionRoundTripsThroughEncoding() {
        let slots: [LimitWindowSlot] = [.week, .fable]
        let raw = MenuBarLimits.encodeSelection(slots)
        #expect(MenuBarLimits.parseSelection(raw, provider: .claude) == slots)
    }

    @Test func groupsDropProvidersWithEmptySelection() {
        let claude = ProviderLimits(
            provider: .claude, session: LimitWindow(percent: 92, resetsAt: nil),
            week: LimitWindow(percent: 68, resetsAt: nil),
            fable: LimitWindow(percent: 46, resetsAt: nil))
        let codex = ProviderLimits(
            provider: .codex, session: nil, week: LimitWindow(percent: 34, resetsAt: nil))
        let groups = MenuBarLimits.groups(
            providers: [claude, codex],
            selection: { $0 == .claude ? [] : [.session, .week] }, masked: false)
        #expect(groups.count == 1)
        #expect(groups[0].provider == .codex)
        #expect(groups[0].segments[0].value == .missing)
        #expect(groups[0].segments[1].value == .percent(34))
    }

    @Test func groupsRoundPercentagesAndKeepWindows() {
        let claude = ProviderLimits(
            provider: .claude, session: LimitWindow(percent: 91.6, resetsAt: now),
            week: nil, fable: LimitWindow(percent: 45.5, resetsAt: now))
        let groups = MenuBarLimits.groups(
            providers: [claude], selection: { _ in [.session, .week, .fable] }, masked: false)
        #expect(groups[0].segments.map(\.value) == [.percent(92), .missing, .percent(46)])
        let cursor = ProviderLimits(
            provider: .cursor, session: LimitWindow(percent: 0.355, resetsAt: now),
            week: LimitWindow(percent: 26.6, resetsAt: now))
        let cursorGroups = MenuBarLimits.groups(
            providers: [cursor], selection: { _ in [.session, .week] }, masked: false)
        #expect(cursorGroups[0].segments.map(\.value) == [.percent(1), .percent(27)])
        #expect(groups[0].segments[0].window?.resetsAt == now)
        #expect(groups[0].segments[0].slot.kind == .session)
        #expect(groups[0].segments[2].slot.kind == .weekly)
    }

    @Test func maskingHidesEveryValue() {
        let claude = ProviderLimits(
            provider: .claude, session: LimitWindow(percent: 92, resetsAt: nil), week: nil,
            fable: nil)
        let groups = MenuBarLimits.groups(
            providers: [claude], selection: { _ in [.session, .week] }, masked: true)
        #expect(groups[0].segments.map(\.value) == [.masked, .masked])
        let codex = ProviderLimits(
            provider: .codex, session: nil, week: nil, credits: 12)
        let codexGroups = MenuBarLimits.groups(
            providers: [codex], selection: { _ in [.credits] }, masked: true)
        #expect(codexGroups[0].segments.map(\.value) == [.masked])
    }

    @Test func styleFallsBackToStacked() {
        let name = "test.menubar.style.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(MenuBarLimits.style(defaults) == .stacked)
        defaults.set("slash", forKey: AppStorageKeys.MenuBar.limitsStyle)
        #expect(MenuBarLimits.style(defaults) == .slash)
        defaults.set("bogus", forKey: AppStorageKeys.MenuBar.limitsStyle)
        #expect(MenuBarLimits.style(defaults) == .stacked)
    }
}
