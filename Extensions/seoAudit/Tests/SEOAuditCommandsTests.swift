import EdithExtensionSupport
import Foundation
import Testing
@testable import SEOAuditExtension

@MainActor @Suite(.serialized) struct SEOAuditCommandsTests {
    @Test func projectCommandsUseStrictOwnedIDsAndPersistCurrentSelection() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let project: SEOAuditProject = try fixture.decode(
            await fixture.call(
                "create", ["url": "synthetic.example.invalid", "name": "Synthetic site"]))
        #expect(project.baseURL == "https://synthetic.example.invalid")
        let projects: [SEOAuditProjectSummary] = try fixture.decode(await fixture.call("list"))
        #expect(projects.map(\.id) == [project.id])
        let renamed: SEOAuditProject = try fixture.decode(
            await fixture.call(
                "rename", ["projectID": project.id.uuidString, "name": "Renamed site"]))
        #expect(renamed.name == "Renamed site")
        let known = project.baseURL + "/known"
        _ = try await fixture.service.setDraft(
            project.id,
            .init(discoveredPageURLs: [known], selectedPageURLs: [], includeLighthouse: false))
        let draft: SEOAuditDraft = try fixture.decode(
            await fixture.call("choose", ["projectID": project.id.uuidString, "mode": "all"]))
        #expect(draft.selectedPageURLs == [known])
        await #expect(throws: SEOAuditInputError.self) {
            _ = try await fixture.call(
                "choose",
                [
                    "projectID": project.id.uuidString, "mode": "only",
                    "urls": ["https://outside.invalid/arbitrary"],
                ])
        }
        _ = try await fixture.call("delete", ["projectID": project.id.uuidString, "confirm": true])
        #expect(try await fixture.service.list().isEmpty)
        fixture.commands.shutdown(); await fixture.service.shutdown()
    }

    @Test func rejectsUnexpectedFieldsInvalidScalarTypesAndExternalPaths() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        for (name, body) in [
            ("list", ["path": "/tmp/arbitrary"]),
            ("create", ["url": "file:///tmp/private"]),
            ("create", ["url": "https://user:secret@example.invalid"]),
            ("create", ["url": "ftp://example.invalid"]),
            ("delete", ["projectID": UUID().uuidString, "confirm": 1]),
            ("run", ["projectID": UUID().uuidString, "offset": true]),
            ("discover", ["projectID": UUID().uuidString, "wait": 1]),
            ("project", ["projectID": "../../outside"]),
        ] as [(String, [String: Any])] {
            await #expect(throws: (any Error).self) { _ = try await fixture.call(name, body) }
        }
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await fixture.commands.execute(
                "seoAudit.list", payload: Data(repeating: 32, count: 131_073))
        }
        let project = try await fixture.service.create(
            url: "https://synthetic.example.invalid", name: "Synthetic")
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await fixture.call("discover", ["projectID": project.id.uuidString, "wait": 1])
        }
        #expect(fixture.service.jobCount == 0)
        fixture.commands.shutdown()
        await #expect(throws: ExtensionPeerError.self) { _ = try await fixture.call("list") }
        await fixture.service.shutdown()
    }

    @Test func largeHistoriesUseOwnedBoundedChunksAndExpireOnShutdown() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let title = String(repeating: "s", count: 32_000)
        let metadata = SEOAuditMetadata(
            title: title, description: nil, canonicalURL: nil, robots: nil, language: nil,
            heading: nil, openGraphTitle: nil, openGraphDescription: nil, openGraphImageURL: nil,
            openGraphImageSnapshotURL: nil, openGraphType: nil, twitterCard: nil, twitterTitle: nil,
            twitterDescription: nil, twitterImageURL: nil, twitterImageSnapshotURL: nil,
            wordCount: 1)
        let pages = (0..<150).map {
            SEOAuditPageResult(
                url: "https://synthetic.example.invalid/\($0)", statusCode: 200,
                responseMilliseconds: 1, bytes: 10, metadata: metadata, issues: [])
        }
        let project = SEOAuditProject(
            name: "Synthetic large history", baseURL: "https://synthetic.example.invalid",
            runs: [.init(state: .completed, pages: pages)])
        try SEOAuditRepository(root: fixture.root).save(project)
        let receipt: SEOAuditCommands.Receipt = try fixture.decode(
            await fixture.call("project", ["projectID": project.id.uuidString]))
        #expect(receipt.byteCount > 4_194_304)
        var data = Data()
        while data.count < receipt.byteCount {
            let chunk: SEOAuditCommands.Chunk = try fixture.decode(
                await fixture.call(
                    "result.chunk", ["resultID": receipt.resultID.uuidString, "offset": data.count])
            )
            #expect(chunk.offset == data.count && chunk.data.count <= 262_144)
            data.append(chunk.data)
            #expect(chunk.finished == (data.count == receipt.byteCount))
        }
        let reconstructed: SEOAuditProject = try fixture.decode(data)
        #expect(reconstructed.id == project.id && reconstructed.runs[0].pages.count == 150)
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await fixture.call(
                "result.chunk", ["resultID": receipt.resultID.uuidString, "offset": 0])
        }
        fixture.commands.shutdown(); await fixture.service.shutdown()
    }

    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        lazy var service = SEOAuditService(
            workflow: SEOAuditWorkflow(
                repository: SEOAuditRepository(root: root),
                lighthouse: LighthouseAuditor(locate: { nil })))
        lazy var commands = SEOAuditCommands(service: service)
        func remove() { try? FileManager.default.removeItem(at: root) }
        func call(_ name: String, _ object: [String: Any] = [:]) async throws -> Data {
            try await commands.execute(
                "seoAudit." + name, payload: JSONSerialization.data(withJSONObject: object))
        }
        func decode<T: Decodable>(_ data: Data) throws -> T {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        }
    }
}
