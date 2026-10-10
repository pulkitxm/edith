import EdithExtensionSupport
import Foundation
import Testing
@testable import CodeStatsExtension

@MainActor @Suite struct CodeStatsSurfaceTests {
    @Test func homeAndNotchUseActualCachedFactsAndBoundedActivity() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for target in [SurfaceTarget.home, .notch] {
            let value = try await fixture.snapshot(target: target)
            #expect(value.providerID == "codeStats")
            #expect(value.metrics.first(where: { $0.id == "commits" })?.value == "3")
            #expect(value.rows.count == 2)
            #expect(value.calendars?.first?.days.count == 126)
            #expect(value.charts?.first?.series.first?.points.count == 30)
            #expect(value.sources.count == 3)
            #expect(try value.encoded().count < 131_072)
        }
        #expect(fixture.harness.engineGits.update { $0.isEmpty })
    }

    @Test func sourceAndContentSettingsApplyBeforeWireEncoding() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.tile.sourceIDs = ["octo/site"]
        fixture.tile.itemLimit = 1
        fixture.tile.hiddenFields = ["commits", "languages", "net"]
        let selected = try await fixture.snapshot()
        #expect(selected.rows.count == 1)
        #expect(selected.rows[0].title == "octo/site")
        #expect(selected.rows[0].detail.isEmpty)
        #expect(!selected.metrics.contains { ["commits", "net"].contains($0.id) })
        fixture.tile.hiddenFields.insert("chart")
        fixture.tile.showActions = false
        let hidden = try await fixture.snapshot()
        #expect(hidden.charts == nil && hidden.calendars == nil)
        #expect(hidden.actions.isEmpty)
        await #expect(throws: ExtensionPeerError.self) { _ = try await fixture.action("open") }
        fixture.tile.sourceIDs = ["unavailable/source"]
        #expect(try await fixture.snapshot().rows.isEmpty)
    }

    @Test func opaqueDayActionsAreRevalidatedAndPrivacyClearsEveryDetail() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let value = try await fixture.snapshot()
        let action = try #require(value.calendars?.first?.days.first?.action)
        _ = try await fixture.action(action.id)
        #expect(fixture.opened == 1)
        for forged in [
            "day:1900-01-01", "/tmp/project", "https://example.invalid", "day:2026-13-42",
        ] {
            await #expect(throws: ExtensionPeerError.self) { _ = try await fixture.action(forged) }
        }
        fixture.privacy = ["active": "1", "blurUsage": "1"]
        let hidden = try await fixture.snapshot()
        #expect(hidden.rows.isEmpty && hidden.metrics.isEmpty && hidden.sources.isEmpty)
        #expect(hidden.charts == nil && hidden.calendars == nil)
        await #expect(throws: ExtensionPeerError.self) { _ = try await fixture.action(action.id) }
        #expect(fixture.opened == 1)
    }

    @MainActor private final class Fixture {
        let harness: CodeStatsWorkflowHarness
        let workflow: CodeStatsWorkflow
        var tile = SurfaceTile(.codeStats)
        var opened = 0
        var privacy: [String: String] = [:]
        lazy var surface = CodeStatsSurface(
            store: harness.store, workflow: workflow, open: { [weak self] in self?.opened += 1 },
            now: { CodeStatsPageFixture.date("2026-10-05") },
            calendar: CodeStatsPageFixture.calendar,
            privacy: { [weak self] in self?.privacy ?? [:] })

        init() throws {
            harness = try CodeStatsWorkflowHarness()
            let environment = CodeStatsEnvironment(
                settings: { .init() }, saveIdentity: { _ in }, isEnabled: { true }, git: { nil },
                github: { nil }, store: harness.store)
            workflow = CodeStatsWorkflow(environment: environment)
            try harness.store.saveFacts(
                CodeStatsFactBuilder.build(commits: CodeStatsPageFixture.commits))
        }
        func remove() { harness.fixture.remove() }
        func snapshot(target: SurfaceTarget = .home) async throws -> SurfaceSnapshot {
            try SurfaceSnapshot.decode(
                await surface.execute(
                    "surface.snapshot",
                    payload: SurfaceSnapshotRequest(target: target, tile: tile).encoded(
                        providerID: "codeStats")), providerID: "codeStats")
        }
        func action(_ id: String) async throws -> Data {
            try await surface.execute(
                "surface.perform",
                payload: SurfaceActionRequest(
                    snapshot: .init(target: .home, tile: tile), actionID: id
                ).encoded(providerID: "codeStats"))
        }
    }
}
