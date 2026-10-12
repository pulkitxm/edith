import EdithExtensionSupport
import Foundation
import Testing

@testable import UsageExtension

@Suite struct UsageAccountProjectionTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func quota(_ name: String, percent: Double = 23) -> ClaudeAccountLimits {
        .init(
            id: UUID(), name: name,
            limits: .init(
                provider: .claude, session: .init(percent: percent, resetsAt: nil),
                week: .init(percent: 41, resetsAt: nil)), refreshedAt: now)
    }

    @Test func namedAccountSelectionIncludesOnlyItsQuotaAndStableSourceIdentity() throws {
        let accounts = [quota("First"), quota("Second", percent: 47)]
        var tile = SurfaceTile(.limits)
        tile.sourceIDs = ["claude-account:" + accounts[1].id.uuidString]
        let value = UsageCompactLimitsSnapshot.project(
            .init(refreshedAt: now, providers: [], failure: nil, claudeAccounts: accounts),
            tile: tile)
        try value.validate()
        #expect(value.rows.count == 2)
        #expect(value.rows.allSatisfy { $0.title.hasPrefix("Second") })
        #expect(value.rows.first?.value == "47% used")
        #expect(
            value.rows.allSatisfy { $0.source == "claude-account:" + accounts[1].id.uuidString })
        #expect(value.sources.contains { $0.id == "claude" })
    }

    @Test func accountProjectionRetainsTheExistingClosedRowAndSourceBounds() throws {
        let accounts = (0..<64).map { quota("Synthetic \($0)") }
        let value = UsageCompactLimitsSnapshot.project(
            .init(refreshedAt: now, providers: [], failure: nil, claudeAccounts: accounts),
            tile: SurfaceTile(.limits))
        try value.validate()
        #expect(value.rows.count == 64)
        #expect(value.sources.count == 16)
        #expect(Set(value.rows.map(\.source)).count == 64)
        #expect(value.metrics.first { $0.id == "accounts" }?.value == "64")
    }

    @Test func compactAccountRowsKeepBothUnavailableWindowsAndSummarizeBeyondTwo() throws {
        let unavailable = ClaudeAccountLimits(
            id: UUID(), name: "Unavailable synthetic account",
            limits: .init(provider: .claude, session: nil, week: nil), refreshedAt: now)
        let small = UsageCompactLimitsSnapshot.project(
            .init(refreshedAt: now, providers: [], failure: nil, claudeAccounts: [unavailable]),
            tile: SurfaceTile(.limits))
        #expect(small.rows.map(\.field) == ["session", "weekly"])
        #expect(small.rows.allSatisfy { $0.value == "Unavailable" })
        let accounts = [quota("First"), quota("Second"), quota("Third")]
        let many = UsageCompactLimitsSnapshot.project(
            .init(refreshedAt: now, providers: [], failure: nil, claudeAccounts: accounts),
            tile: SurfaceTile(.limits))
        try many.validate()
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
    }

    @Test func menuBarAccountPreferenceAcceptsOnlyAnEmptyOrUUIDSelection() throws {
        try UsageUIPreferences(values: [MenuBarLimits.accountSelectionKey: .text(UUID().uuidString)]
        ).validate()
        #expect(throws: ExtensionPeerError.self) {
            try UsageUIPreferences(values: [
                MenuBarLimits.accountSelectionKey: .text("synthetic-token")
            ]).validate()
        }
    }

    @Test @MainActor func namedQuotasStayHiddenByTheExistingSurfacePresentationPolicy() async throws
    {
        let accounts = [quota("Private synthetic account")]
        let controller = UsageWorkerController(allowsBackgroundCollection: { false }) { _, _ in
            Data()
        }
        let surface = UsageSurface(
            store: SurfaceUsageStore(url: URL(fileURLWithPath: "/synthetic/usage.json")),
            controller: controller,
            limits: {
                .init(refreshedAt: now, providers: [], failure: nil, claudeAccounts: accounts)
            },
            privacy: { ["active": "1", "blurUsage": "1"] })
        let snapshot = try await surface.snapshot(SurfaceTile(.limits))
        #expect(snapshot.rows.isEmpty)
        #expect(snapshot.sources.isEmpty)
        #expect(snapshot.message == "Hidden while presenting.")
        await controller.shutdown()
    }

    @Test @MainActor func defaultSurfaceProjectsItsOwnedWorkersNamedAccountQuota() async throws {
        let accounts = [quota("Owned synthetic account")]
        let snapshot = LimitsTopicSnapshot(
            refreshedAt: now, providers: [], failure: nil, claudeAccounts: accounts)
        let controller = UsageWorkerController(
            fetchLimits: { _ in snapshot }, allowsBackgroundCollection: { false }
        ) { _, _ in Data() }
        try controller.requestLimitsRefresh()
        try await controller.waitForLimitsRefresh()
        let surface = UsageSurface(
            store: SurfaceUsageStore(url: URL(fileURLWithPath: "/synthetic/usage.json")),
            controller: controller, privacy: { [:] })
        let value = try await surface.snapshot(SurfaceTile(.limits))
        #expect(value.rows.contains { $0.title.contains("Owned synthetic account") })
        #expect(value.sources.contains { $0.id == "claude-account:" + accounts[0].id.uuidString })
        await controller.shutdown()
    }
}
