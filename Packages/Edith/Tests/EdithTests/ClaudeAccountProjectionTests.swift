import Foundation
import Testing

@testable import EdithKit

@Suite struct ClaudeAccountProjectionTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func quota(_ name: String, percent: Double = 23) -> ClaudeAccountLimits {
        .init(
            id: UUID(), name: name,
            limits: .init(
                provider: .claude, session: .init(percent: percent, resetsAt: nil),
                week: .init(percent: 41, resetsAt: nil)), refreshedAt: now)
    }

    private func project(
        _ accounts: [ClaudeAccountLimits], tile: SurfaceTile = SurfaceTile(.limits)
    )
        -> SurfaceExtensionSnapshot
    {
        SurfaceCoreProjection.limits(
            .init(
                refreshedAt: now,
                providers: [.init(provider: .claude, session: nil, week: nil)], failure: nil,
                claudeAccounts: accounts),
            tile: tile, now: now)
    }

    @Test func namedAccountSelectionIncludesOnlyItsQuotaAndStableSourceIdentity() {
        let accounts = [quota("First"), quota("Second", percent: 47)]
        var tile = SurfaceTile(.limits)
        tile.sourceIDs = ["claude-account:" + accounts[1].id.uuidString]
        let value = project(accounts, tile: tile)
        #expect(value.rows.count == 2)
        #expect(value.rows.allSatisfy { $0.title.hasPrefix("Second") })
        #expect(value.rows.first?.value == "47% used")
        #expect(
            value.rows.allSatisfy { $0.sourceID == "claude-account:" + accounts[1].id.uuidString })
        #expect(value.sources.contains { $0.id == "claude" })
        #expect(!value.sources.contains { $0.title == LimitProvider.claude.label })
    }

    @Test func accountProjectionRetainsTheExistingClosedRowAndSourceBounds() {
        let value = project((0..<64).map { quota("Synthetic \($0)") })
        #expect(value.rows.count == 64)
        #expect(value.sources.count == 16)
        #expect(Set(value.rows.map(\.sourceID)).count == 64)
        #expect(value.metrics.first { $0.id == "accounts" }?.value == "64")
    }

    @Test func compactAccountRowsKeepBothUnavailableWindowsAndSummarizeBeyondTwo() {
        let unavailable = ClaudeAccountLimits(
            id: UUID(), name: "Unavailable synthetic account",
            limits: .init(provider: .claude, session: nil, week: nil), refreshedAt: now)
        let small = project([unavailable])
        #expect(small.rows.map(\.field) == ["session", "weekly"])
        #expect(small.rows.allSatisfy { $0.value == "Unavailable" })
        let accounts = [quota("First"), quota("Second"), quota("Third")]
        let many = project(accounts)
        #expect(many.rows.count == 3)
        #expect(many.rows.map(\.title) == accounts.map(\.name))
        #expect(many.rows.allSatisfy { $0.value == "59% left" && $0.details.count == 2 })
        #expect(many.metrics.first { $0.id == "accounts" }?.value == "3")
    }

    @Test func namedStatusGroupsShowBothSmallAccountsAndMaskNamesValuesAndRemainder() {
        let accounts = [quota("First"), quota("Second"), quota("Third", percent: 47)]
        let small = MenuBarLimits.accountGroups(
            Array(accounts.prefix(2)), selectedID: nil, slots: [.session, .week], masked: false)
        #expect(small.map(\.accountLabel) == ["First", "Second"])
        #expect(small.allSatisfy { $0.remainingAccounts == 0 })
        let selected = MenuBarLimits.accountGroups(
            accounts, selectedID: accounts[2].id.uuidString, slots: [.session], masked: false)
        #expect(selected.count == 1)
        #expect(selected.first?.accountLabel == "Third")
        #expect(selected.first?.segments.first?.value == .percent(47))
        #expect(selected.first?.remainingAccounts == 2)
        let masked = MenuBarLimits.accountGroups(
            accounts, selectedID: accounts[2].id.uuidString, slots: [.session, .week], masked: true)
        #expect(masked.first?.accountLabel == "Account")
        #expect(masked.first?.remainingAccounts == 0)
        #expect(masked.first?.segments.allSatisfy { $0.value == .masked } == true)
    }

    @Test func menuBarSelectsTheSavedAccountAndFallsBackAfterRemoval() {
        let accounts = [quota("First"), quota("Second", percent: 47), quota("Third")]
        let selected = MenuBarLimits.accountGroups(
            accounts, selectedID: accounts[1].id.uuidString, slots: [.session], masked: false)
        #expect(selected.first?.segments.first?.value == .percent(47))
        let removed = MenuBarLimits.accountGroups(
            [accounts[0]], selectedID: accounts[1].id.uuidString, slots: [.session], masked: false)
        #expect(removed.first?.segments.first?.value == .percent(23))
        let expired = ClaudeAccountLimits(
            id: UUID(), name: "Expired",
            limits: .init(
                provider: .claude,
                session: .init(percent: 99, resetsAt: .distantPast), week: nil), refreshedAt: now)
        let missing = MenuBarLimits.accountGroups(
            [expired], selectedID: nil, slots: [.session], masked: false)
        #expect(missing.first?.segments.first?.value == .missing)
        #expect(missing.first?.hasPercent == false)
        #expect(selected.first?.hasPercent == true)
    }

    @Test func stackedHeadersPreserveShortLabelsAndMaskIdentity() {
        let source = ["First synthetic account", "Second synthetic account"].map {
            quota($0)
        }
        let groups = MenuBarLimits.accountGroups(
            source, selectedID: nil, slots: [.session, .week], masked: false)
        #expect(groups.map(\.accountHeader) == source.map { String($0.name.prefix(16)) })
        #expect(groups.map(\.accountLabel) == source.map { String($0.name.prefix(8)) })
        let hidden = MenuBarLimits.accountGroups(
            source + source, selectedID: nil, slots: [.session, .week], masked: true)
        #expect(hidden.allSatisfy { $0.accountHeader == "Account" && $0.accountLabel == "Account" })
        #expect(hidden.allSatisfy { $0.remainingAccounts == 0 })
    }

    @Test func topicSnapshotsFromOlderAgentsDecodeWithoutAccounts() throws {
        let data = Data(
            #"{"refreshedAt":0,"providers":[],"failure":null}"#.utf8)
        let decoded = try JSONDecoder().decode(LimitsTopicSnapshot.self, from: data)
        #expect(decoded.claudeAccounts.isEmpty)
        let accounts = [quota("Synthetic")]
        let snapshot = LimitsTopicSnapshot(
            refreshedAt: now, providers: [], failure: nil, claudeAccounts: accounts)
        let round = try JSONDecoder().decode(
            LimitsTopicSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(round == snapshot)
    }
}
