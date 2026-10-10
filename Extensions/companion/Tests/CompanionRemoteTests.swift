import EdithExtensionSupport
import Foundation
import Testing
@testable import CompanionExtension

@Suite(.serialized) @MainActor struct CompanionRemoteTests {
    @Test func fixedRoutesRejectArbitraryReadsAndTransfersUseTheOwnedEndpoint() async throws {
        actor Network {
            var requests: [URLRequest] = []
            func read(_ request: URLRequest) -> (Data, URLResponse) {
                requests.append(request)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 206, httpVersion: nil,
                    headerFields: ["Content-Type": "application/pdf"])!
                return (Data(repeating: 7, count: 5_242_880), response)
            }
        }
        let network = Network()
        let worker = CompanionWorker(transport: CompanionTransport())
        let engine = CompanionUIEngine(
            worker: worker, endpoint: { URL(string: "http://fixture.invalid:4820")! },
            read: { await network.read($0) })
        let bridge = CompanionUIBridge(invoke: { try await engine.execute($0, payload: $1) })
        let request = URLRequest(
            url: URL(string: "http://untrusted.invalid/v1/episodes/synthetic/media")!)
        let (data, response) = try await bridge.http(request)
        #expect(data.count == 5_242_880 && data.first == 7)
        #expect((response as? HTTPURLResponse)?.statusCode == 206)
        let requests = await network.requests
        #expect(requests.count == 1 && requests[0].url?.host == "fixture.invalid")
        await #expect(throws: (any Error).self) {
            _ = try await bridge.http(
                URLRequest(url: URL(string: "http://untrusted.invalid/v1/private/secrets")!))
        }
        #expect(await network.requests.count == 1)
        await engine.shutdown()
        await #expect(throws: (any Error).self) { _ = try await bridge.http(request) }
        await worker.shutdown()
    }

    @Test func capturePresentationStopsWithoutStartingOrStoppingTheEngine() async throws {
        let worker = CompanionWorker(transport: CompanionTransport())
        let engine = CompanionUIEngine(worker: worker)
        let bridge = CompanionUIBridge(invoke: { try await engine.execute($0, payload: $1) })
        let ui = CompanionCaptureModel(remote: bridge)
        await ui.refreshWaiting()
        #expect(ui.phase == .idle && ui.waiting.isEmpty)
        await #expect(throws: (any Error).self) { _ = try await bridge.capture("toggle", note: "") }
        ui.shutdown()
        #expect(!worker.isStopped && worker.workspace.capture.phase == .idle)
        await engine.shutdown(); await worker.shutdown()
    }

    @Test func stoppedPresentationTransportCannotFallBackToLocalNetwork() async throws {
        let transport = CompanionTransport()
        let worker = CompanionWorker(transport: CompanionTransport())
        let engine = CompanionUIEngine(worker: worker)
        let bridge = CompanionUIBridge(invoke: { try await engine.execute($0, payload: $1) })
        transport.configureRemote(bridge)
        transport.configureRemote(nil)
        let request = URLRequest(url: URL(string: "http://127.0.0.1:4820/v1/status")!)
        await #expect(throws: CancellationError.self) { _ = try await transport.data(for: request) }
        #expect(throws: CancellationError.self) { _ = try transport.session }
        #expect(throws: ExtensionPeerError.self) {
            try CompanionUIPreferences.apply(.init(key: "host.private", value: "true"))
        }
        #expect(throws: ExtensionPeerError.self) {
            try CompanionUIPreferences.apply(
                .init(key: AppStorageKeys.Companion.endpoint, value: "file:///private"))
        }
        await engine.shutdown(); await worker.shutdown()
    }

    @Test func stopBypassesTerminalOutputCaptureAndCancelsOwnedGeneration() async throws {
        var stopped = false
        let id = CompanionGeneration.track { stopped = true }
        defer { CompanionGeneration.forget(id) }
        let reply = try await CompanionCLIExecution.run(.init(arguments: ["stop", "--json"]))
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(reply.stdout.utf8)) as? [String: Any])
        #expect(stopped && reply.exitCode == 0 && reply.stderr.isEmpty)
        #expect(object["window"] as? Int == 1 && (object["commands"] as? [Any])?.isEmpty == true)
        let invalid = try await CompanionCLIExecution.run(.init(arguments: ["stop", "--unknown"]))
        #expect(invalid.exitCode == 2 && invalid.stdout.isEmpty)
    }

    @Test func originalCommandHierarchyAndConfigurationValidationArePreserved() async throws {
        let help = try await CompanionCLIExecution.run(.init(arguments: ["--help"]))
        #expect(
            help.exitCode == 0 && help.stdout.contains("stack") && help.stdout.contains("core")
                && help.stdout.contains("stop"))
        let chat = try await CompanionCLIExecution.run(.init(arguments: ["chat", "--help"]))
        #expect(
            chat.exitCode == 0 && chat.stdout.contains("--conversation")
                && chat.stdout.contains("--persona"))
        let invalid = try await CompanionCLIExecution.run(
            .init(arguments: ["stack", "missing-operation"]))
        #expect(invalid.exitCode != 0 && invalid.stderr.contains("missing-operation"))
    }
}
