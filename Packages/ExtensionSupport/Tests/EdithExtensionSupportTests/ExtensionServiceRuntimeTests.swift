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
    var requiresOwnedDataDirectory = false
    var preparesForDisable = false
    var disablePreparations = 0

    func prepareDisable() async throws {
        disablePreparations += 1
        if disablePreparations > 1 { throw ExtensionPeerError.unavailable }
    }

    var startInputs: [String] = []

    func start(_ context: ExtensionStartContext) -> Bool {
        starts += 1
        startInputs.append(context.dataDirectory ?? "")
        return !context.isHostedFunctionalFixture
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

private let syntheticSuite = "edith.synthetic.service.runtime"
private let syntheticDataRoot = "/tmp/edith-synthetic-service-data"
private let syntheticScope = [
    "EDITH_SHARED_DEFAULTS_SUITE": syntheticSuite, "EDITH_EXTENSION_DATA_ROOT": syntheticDataRoot,
]

@MainActor
@Suite(.serialized) struct ExtensionServiceRuntimeTests {
    private static let suite = syntheticSuite
    private static let dataRoot = syntheticDataRoot

    private func runtime(owningData: Bool = false) -> (ExtensionServiceRuntime, SyntheticService) {
        ExtensionScope.register(
            ExtensionScope(
                environment: { syntheticScope },
                value: { syntheticScope[$0] },
                defaults: { .standard },
                dataRoot: { ExtensionScope.temporaryDataRoot() }),
            image: #dsohandle)
        let service = SyntheticService()
        service.requiresOwnedDataDirectory = owningData
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

    @Test func startNeedsTheScopedDataDirectoryWhenTheServiceOwnsData() {
        let (runtime, service) = runtime(owningData: true)
        #expect(ok(runtime.execute(["operation": "start", "defaultsSuite": Self.suite])) == false)
        #expect(
            ok(
                runtime.execute([
                    "operation": "start", "defaultsSuite": Self.suite,
                    "dataDirectory": "/tmp/other",
                ])) == false)
        #expect(
            ok(
                runtime.execute([
                    "operation": "start", "defaultsSuite": Self.suite,
                    "dataDirectory": Self.dataRoot + "/",
                ])) == true)
        #expect(service.starts == 1)
        #expect(service.startInputs == [Self.dataRoot + "/"])
    }

    @Test func serviceStartSeesTheHostInputAndCanRefuseIt() {
        let (runtime, service) = runtime()
        #expect(
            ok(
                runtime.execute([
                    "operation": "start", "defaultsSuite": Self.suite,
                    "hostedFunctionalFixture": true,
                ])) == false)
        #expect(ok(runtime.execute(["operation": "start", "defaultsSuite": Self.suite])) == true)
        #expect(service.starts == 2)
    }

    @Test func disablePreparationIsOfferedOnlyWhenTheServiceDeclaresIt() async {
        let selector = NSSelectorFromString("prepareDisableWithCompletion:")
        let (plain, _) = runtime()
        #expect(!plain.responds(to: selector))
        let (runtime, service) = runtime()
        service.preparesForDisable = true
        #expect(runtime.responds(to: selector))
        _ = runtime.execute(["operation": "start", "defaultsSuite": Self.suite])
        let first = await withCheckedContinuation { continuation in
            runtime.prepareDisable { continuation.resume(returning: $0) }
        }
        #expect(first == nil)
        #expect(runtime.isSuspended && service.cancellations == 1 && service.drains == 1)
        #expect(await invoke(runtime, "synthetic.late")?.hasPrefix("error:") == true)
        let second = await withCheckedContinuation { continuation in
            runtime.prepareDisable { continuation.resume(returning: $0) }
        }
        #expect(second != nil)
        await runtime.stop()
        #expect(service.teardowns == 1)
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
