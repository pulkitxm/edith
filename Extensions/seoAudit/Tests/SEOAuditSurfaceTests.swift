import EdithExtensionSupport
import Foundation
import Testing
@testable import SEOAuditExtension

@MainActor @Suite(.serialized) struct SEOAuditSurfaceTests {
    @Test func homeAndNotchUseSavedProjectMetricsWithoutLaunchingAudits() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for target in [SurfaceTarget.home, .notch] {
            let snapshot = try await fixture.snapshot(target)
            #expect(snapshot.providerID == "seoAudit")
            #expect(snapshot.rows.count == 2)
            #expect(snapshot.metrics.first { $0.id == "pages" }?.value == "2")
            #expect(snapshot.sources.count == 2)
            #expect(fixture.service.jobCount == 0)
        }
        fixture.tile.sourceIDs = [fixture.project.id.uuidString.lowercased()]
        fixture.tile.itemLimit = 1
        fixture.tile.hiddenFields = ["pages", "metadata"]
        let selected = try await fixture.snapshot()
        #expect(
            selected.rows.count == 1
                && selected.rows[0].sourceID == fixture.project.id.uuidString.lowercased())
        #expect(selected.rows[0].detail.isEmpty)
        #expect(!selected.metrics.contains { $0.id == "pages" })
        fixture.tile.sourceIDs = [UUID().uuidString.lowercased()]
        #expect(try await fixture.snapshot().rows.isEmpty)
        await fixture.service.shutdown()
    }

    @Test func currentProjectActionsRespectSourceFiltersDeletionAndPrivacy() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let action = "open:" + fixture.project.id.uuidString.lowercased()
        _ = try await fixture.action(action)
        #expect(fixture.opened == [fixture.project.id])
        for forged in [
            "open:/tmp/private", "audit:https://example.invalid", "open:" + UUID().uuidString,
        ] {
            await #expect(throws: ExtensionPeerError.self) { _ = try await fixture.action(forged) }
        }
        fixture.tile.sourceIDs = [UUID().uuidString.lowercased()]
        await #expect(throws: ExtensionPeerError.self) { _ = try await fixture.action(action) }
        fixture.tile.sourceIDs = nil
        fixture.privacy = ["active": "1", "blurSiteAudit": "1", "blurShelf": "0"]
        let hidden = try await fixture.snapshot()
        #expect(hidden.rows.isEmpty && hidden.metrics.isEmpty && hidden.sources.isEmpty)
        await #expect(throws: ExtensionPeerError.self) { _ = try await fixture.action(action) }
        fixture.privacy = ["active": "1", "blurSiteAudit": "0"]
        #expect(try await fixture.snapshot().rows.count == 2)
        try await fixture.service.delete(fixture.project.id)
        await #expect(throws: ExtensionPeerError.self) { _ = try await fixture.action(action) }
        #expect(fixture.opened == [fixture.project.id])
        await fixture.service.shutdown()
    }

    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project: SEOAuditProject
        let service: SEOAuditService
        var tile = SurfaceTile(.ability("seoAudit"))
        var opened: [UUID?] = []
        var privacy: [String: String] = [:]
        lazy var surface = SEOAuditSurface(
            service: service, open: { [weak self] id in self?.opened.append(id) },
            privacy: { [weak self] in self?.privacy ?? [:] })
        init() throws {
            let repository = SEOAuditRepository(root: root)
            let page = SEOAuditPageResult(
                url: "https://synthetic.example.invalid/page", statusCode: 200,
                responseMilliseconds: 1, bytes: 10, metadata: .empty,
                issues: [
                    .init(
                        code: "title", severity: .error, title: "Missing title",
                        detail: "Add a title")
                ])
            project = SEOAuditProject(
                name: "Synthetic site", baseURL: "https://synthetic.example.invalid",
                runs: [.init(state: .completed, pages: [page])])
            try repository.save(project)
            try repository.save(
                SEOAuditProject(
                    name: "Another synthetic site", baseURL: "https://second.example.invalid",
                    runs: [.init(state: .completed, pages: [page])]))
            service = SEOAuditService(
                workflow: SEOAuditWorkflow(
                    repository: repository, lighthouse: LighthouseAuditor(locate: { nil })))
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func snapshot(_ target: SurfaceTarget = .home) async throws -> SurfaceSnapshot {
            try SurfaceSnapshot.decode(
                await surface.execute(
                    "surface.snapshot",
                    payload: SurfaceSnapshotRequest(target: target, tile: tile).encoded(
                        providerID: "seoAudit")), providerID: "seoAudit")
        }
        func action(_ id: String) async throws -> Data {
            try await surface.execute(
                "surface.perform",
                payload: SurfaceActionRequest(
                    snapshot: .init(target: .home, tile: tile), actionID: id
                ).encoded(providerID: "seoAudit"))
        }
    }
}
