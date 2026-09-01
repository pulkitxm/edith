import Foundation
import Testing

@testable import EdithKit

@Suite struct MenuBarLimitsTests {
    let now = Date(timeIntervalSince1970: 1_787_000_000)

    @Test func missingSelectionShowsEveryWindow() {
        #expect(
            MenuBarLimits.parseSelection(nil, provider: .claude) == [.session, .week, .fable])
        #expect(MenuBarLimits.parseSelection(nil, provider: .codex) == [.session, .week])
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

@Suite struct ClaudeUsageParserTests {
    @Test func parsesWindowsAndScopedFableLimit() throws {
        let json = """
            {
              "five_hour": {"utilization": 92.0, "resets_at": "2026-08-16T09:40:00.194607+00:00"},
              "seven_day": {"utilization": 68.0, "resets_at": "2026-08-20T08:00:00.194626+00:00"},
              "seven_day_opus": null,
              "limits": [
                {"kind": "session", "group": "session", "percent": 92, "severity": "critical",
                 "resets_at": "2026-08-16T09:40:00.194607+00:00", "scope": null, "is_active": true},
                {"kind": "weekly_all", "group": "weekly", "percent": 68, "severity": "normal",
                 "resets_at": "2026-08-20T08:00:00.194626+00:00", "scope": null, "is_active": false},
                {"kind": "weekly_scoped", "group": "weekly", "percent": 46, "severity": "normal",
                 "resets_at": "2026-08-20T08:00:00.194774+00:00",
                 "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null},
                 "is_active": false}
              ]
            }
            """
        let result = try ClaudeUsageParser.parse(Data(json.utf8))
        #expect(result.session?.percent == 92)
        #expect(result.week?.percent == 68)
        #expect(result.fable?.percent == 46)
        #expect(result.session?.resetsAt != nil)
        #expect(result.fable?.resetsAt != nil)
    }

    @Test func missingLimitsArrayMeansNoFableWindow() throws {
        let json = """
            {"five_hour": {"utilization": 12.0, "resets_at": null}, "seven_day": null}
            """
        let result = try ClaudeUsageParser.parse(Data(json.utf8))
        #expect(result.session?.percent == 12)
        #expect(result.week == nil)
        #expect(result.fable == nil)
    }

    @Test func unscopedOrUnnamedLimitsAreIgnoredUnlessModelScoped() throws {
        let json = """
            {
              "limits": [
                {"kind": "weekly_scoped", "percent": 30, "resets_at": null,
                 "scope": {"model": {"id": "m1", "display_name": "Other"}}},
                {"kind": "weekly_all", "percent": 70, "resets_at": null, "scope": null}
              ]
            }
            """
        let result = try ClaudeUsageParser.parse(Data(json.utf8))
        #expect(result.fable?.percent == 30)
    }
}
