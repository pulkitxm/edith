import AppKit
import Foundation
import Testing

@testable import EdithExtensionCore

@MainActor
private final class SyntheticService: ExtensionService {
    var starts = 0
    var cancellations = 0
    var drains = 0
    var teardowns = 0
    var invocations: [String] = []

    func start() -> Bool {
        starts += 1
        return true
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        invocations.append(command)
        return Data(command.utf8)
    }

    func cancelPendingWork() { cancellations += 1 }
    func drain() async { drains += 1 }
    func teardown() async { teardowns += 1 }

    func perform(_ operation: String, context: NSDictionary) -> NSObject? {
        operation == "toggle" ? (["ok": true, "toggled": true] as NSDictionary) : nil
    }
}

@MainActor
@Suite(.serialized) struct ExtensionServiceRuntimeTests {
    private static let suite = "edith.synthetic.service.runtime"

    private func runtime() -> (ExtensionServiceRuntime, SyntheticService) {
        ExtensionScope.register(
            ExtensionScope(
                environment: { ["EDITH_SHARED_DEFAULTS_SUITE": Self.suite] },
                value: { $0 == "EDITH_SHARED_DEFAULTS_SUITE" ? Self.suite : nil },
                defaults: { .standard },
                dataRoot: { ExtensionScope.temporaryDataRoot() }),
            image: #dsohandle)
        let service = SyntheticService()
        let runtime = ExtensionServiceRuntime(id: "synthetic", role: "app", bundle: .main) { _ in
            service
        }
        return (runtime, service)
    }

    private func invoke(_ runtime: ExtensionServiceRuntime, _ command: String) async -> String? {
        await withCheckedContinuation { continuation in
            runtime.invoke(
                [
                    "token": UUID().uuidString, "command": command, "payload": Data(),
                ] as NSDictionary
            ) { data, message in
                continuation.resume(
                    returning: data.map { String(decoding: $0 as Data, as: UTF8.self) }
                        ?? message.map { "error: \($0)" })
            }
        }
    }

    private func ok(_ value: NSObject) -> Bool? { (value as? NSDictionary)?["ok"] as? Bool }

    @Test func describeReportsIdentityAndStartNeedsTheScopedSuite() {
        let (runtime, service) = runtime()
        let description = runtime.execute(["operation": "describe"]) as? NSDictionary
        #expect(description?["id"] as? String == "synthetic")
        #expect(description?["role"] as? String == "app")
        #expect(ok(runtime.execute(["operation": "start", "defaultsSuite": "other"])) == false)
        #expect(ok(runtime.execute(["operation": "start", "defaultsSuite": Self.suite])) == true)
        #expect(ok(runtime.execute(["operation": "start", "defaultsSuite": Self.suite])) == true)
        #expect(service.starts == 1)
        let status = runtime.execute(["operation": "status"]) as? NSDictionary
        #expect(status?["running"] as? Bool == true)
    }

    @Test func commandsRunUntilTeardownAndCustomOperationsReachTheService() async {
        let (runtime, service) = runtime()
        _ = runtime.execute(["operation": "start", "defaultsSuite": Self.suite])
        #expect(await invoke(runtime, "synthetic.ping") == "synthetic.ping")
        let toggled = runtime.execute(["operation": "toggle"]) as? NSDictionary
        #expect(toggled?["toggled"] as? Bool == true)
        #expect(ok(runtime.execute(["operation": "unknown"])) == false)
        _ = runtime.execute(["operation": "stop"])
        #expect(await invoke(runtime, "synthetic.late")?.hasPrefix("error:") == true)
        #expect(service.invocations == ["synthetic.ping"])
    }

    @Test func overlappingStopsTearDownOnce() async {
        let (runtime, service) = runtime()
        _ = runtime.execute(["operation": "start", "defaultsSuite": Self.suite])
        _ = runtime.execute(["operation": "stop"])
        await withCheckedContinuation { continuation in
            runtime.suspendCommands { continuation.resume() }
        }
        await withCheckedContinuation { continuation in
            runtime.prepareToStop { continuation.resume() }
        }
        await withCheckedContinuation { continuation in
            runtime.prepareToStop { continuation.resume() }
        }
        #expect(service.cancellations == 1)
        #expect(service.drains == 1)
        #expect(service.teardowns == 1)
        let status = runtime.execute(["operation": "status"]) as? NSDictionary
        #expect(status?["running"] as? Bool == false)
        #expect(ok(runtime.execute(["operation": "start", "defaultsSuite": Self.suite])) == false)
    }
}
