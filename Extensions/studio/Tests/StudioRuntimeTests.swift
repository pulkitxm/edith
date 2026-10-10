import EdithExtensionSupport
import Foundation
import Testing
@testable import StudioExtension

@MainActor @Suite(.serialized) struct StudioRuntimeTests {
    private func invoke(_ runtime: ExtensionRuntime, command: String, payload: Data) async
        -> (Data?, String?)
    {
        await withCheckedContinuation { continuation in
            runtime.invoke(
                ["token": UUID().uuidString, "command": command, "payload": payload] as NSDictionary
            ) { bytes, failure in
                continuation.resume(
                    returning: (bytes.map { $0 as Data }, failure.map { $0 as String }))
            }
        }
    }

    @Test func ownedRuntimeInvokesOriginalCLIAndRejectsAfterDisable() async throws {
        let runtime = ExtensionRuntime()
        let suite = try #require(ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"])
        let started = runtime.execute(
            ["operation": "start", "defaultsSuite": suite] as NSDictionary)
        #expect((started as? NSDictionary)?["ok"] as? Bool == true)
        let request = try StudioCLIRequest(
            arguments: ["info", "nonexistent.tool"], workingDirectory: "/tmp")
        let (bytes, failure) = await invoke(
            runtime, command: "studio.cli", payload: try JSONEncoder().encode(request))
        #expect(failure == nil)
        let reply = try JSONDecoder().decode(ExtensionCLIReply.self, from: #require(bytes))
        #expect(reply.exitCode == 3 && reply.stdout.isEmpty)
        #expect(reply.stderr.contains("no Studio tool called nonexistent.tool"))
        await withCheckedContinuation { continuation in
            runtime.prepareToStop { continuation.resume() }
        }
        let status = runtime.execute(["operation": "status"] as NSDictionary)
        #expect((status as? NSDictionary)?["running"] as? Bool == false)
        let (disabledBytes, disabledFailure) = await invoke(
            runtime, command: "studio.cli", payload: try JSONEncoder().encode(request))
        #expect(disabledBytes == nil && disabledFailure != nil)
    }

    @Test func remoteUIContextCannotStartOwnedNativeServices() throws {
        let runtime = ExtensionRuntime()
        let suite = try #require(ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"])
        let result = runtime.execute(
            ["operation": "start", "remoteUI": true, "defaultsSuite": suite]
                as NSDictionary)
        #expect((result as? NSDictionary)?["ok"] as? Bool == false)
        let status = runtime.execute(["operation": "status"] as NSDictionary)
        #expect((status as? NSDictionary)?["running"] as? Bool == false)
    }
}
