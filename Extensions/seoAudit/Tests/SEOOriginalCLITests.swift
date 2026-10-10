import EdithExtensionSupport
import Foundation
import Testing
@testable import SEOAuditExtension

@Suite(.serialized) @MainActor struct SEOOriginalCLITests {
    @Test func originalCommandsAndRemoteSelectionShareTheOwnedRepository() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SEOAuditService(
            workflow: SEOAuditWorkflow(
                repository: .init(root: root), lighthouse: .init(locate: { nil })))
        let engine = SEOAuditUIEngine(service: service)
        let bridge = SEOAuditUIBridge(invoke: { try await engine.execute($0, payload: $1) })
        let ui = SEOAuditService(remote: bridge)
        let created = try await SEOCLIExecution.run(
            .init(arguments: [
                "create", "https://synthetic.example.invalid", "--name", "Synthetic", "--json",
            ]), service: service)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(created.stdout.utf8)) as? [String: Any])
        let id = try #require((object["id"] as? String).flatMap(UUID.init(uuidString:)))
        #expect(created.exitCode == 0)
        #expect(try await ui.project(id).name == "Synthetic")
        let url = "https://synthetic.example.invalid/known"
        _ = try await ui.setDraft(
            id, .init(discoveredPageURLs: [url], selectedPageURLs: [url], includeLighthouse: false))
        _ = try await ui.choose(id, edit: .none)
        #expect(try await service.draft(id).selectedPageURLs.isEmpty)
        await #expect(throws: (any Error).self) {
            _ = try await ui.choose(id, edit: .add(["https://unowned.invalid/private"]))
        }
        let renamed = try await SEOCLIExecution.run(
            .init(arguments: ["rename", id.uuidString, "Renamed", "--json"]), service: service)
        #expect(renamed.exitCode == 0)
        #expect(try await ui.project(id).name == "Renamed")
        let preview = try await SEOCLIExecution.run(
            .init(arguments: ["delete", id.uuidString, "--json"]), service: service)
        #expect(preview.exitCode == 0)
        #expect(try await ui.list().count == 1)
        let help = try await SEOCLIExecution.run(.init(arguments: ["--help"]), service: service)
        #expect(
            help.exitCode == 0 && help.stdout.contains("lighthouse")
                && help.stdout.contains("pages"))
        await ui.shutdown()
        #expect(!service.isStopped)
        engine.shutdown(); await service.shutdown()
    }
}
