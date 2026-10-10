import Foundation
import Testing

@testable import EdithHostCore

@MainActor
@Suite
struct HostFolderChoiceWorkerTests {
    @Test(arguments: ["selected", "cancelled", "invalid"])
    func actualWorkerTransportPreservesClosedFolderResults(_ outcome: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("reply.json")
        let bytes = try JSONSerialization.data(withJSONObject: [
            "identifier": "com.pulkit.edith.tests." + UUID().uuidString,
            "supportDirectory": root.absoluteString, "extensionID": "herdr", "version": "1",
            "theme": "accent", "appearance": "system", "zoom": 1, "recoveryOnly": false,
        ])
        let configuration = try JSONDecoder().decode(HostWorkerConfiguration.self, from: bytes)
        let script = try #require(
            Bundle.module.url(forResource: "worker", withExtension: "py", subdirectory: "Fixtures"))
        let worker = HostWorker(
            configuration: configuration, executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [script.path, "folder-choice", output.path], requestTimeout: .seconds(3))
        var callbacks = 0
        worker.didRequestFolderChoice = { request in
            callbacks += 1
            #expect(request.extensionID == "herdr" && request.version == "1")
            #expect(request.location == "settings" && request.section == "agentActivity")
            #expect(request.folderChoice == true && request.presentationID != nil)
            switch outcome {
            case "selected": return .init(selectedPath: "/synthetic/projects")
            case "cancelled": return .init(cancelled: true)
            default: return .init(selectedPath: "/synthetic/../foreign")
            }
        }
        do {
            try await worker.start()
            if outcome == "invalid" {
                await #expect(throws: HostWorkerError.rejected) { try await worker.show() }
            } else {
                try await worker.show()
            }
            let reply = try JSONDecoder().decode(
                HostWorkerNavigationReply.self, from: Data(contentsOf: output))
            #expect(callbacks == 1)
            #expect(reply.ok == (outcome != "invalid"))
            #expect(reply.selectedPath == (outcome == "selected" ? "/synthetic/projects" : nil))
            #expect(reply.folderCancelled == (outcome == "cancelled" ? true : nil))
            #expect(worker.ready)
            try await worker.stop()
            #expect(worker.processIdentifier == nil)
        } catch {
            try? await worker.stop()
            throw error
        }
    }
}
