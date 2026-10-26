import EdithExtensionSupport
import Foundation
import Testing

@testable import CompanionExtension

@Suite(.serialized) @MainActor
struct CompanionWindowTransportTests {
    @Test func closingAnotherWindowPreservesAnInFlightRequestAndMediaReads() async throws {
        let firstNetwork = WindowRequestFixture(name: "first")
        let secondNetwork = WindowRequestFixture(name: "second")
        let firstWorker = CompanionWorker(transport: CompanionTransport())
        let secondWorker = CompanionWorker(transport: CompanionTransport())
        let firstEngine = CompanionUIEngine(
            worker: firstWorker, endpoint: { URL(string: "http://fixture.invalid:4820")! },
            read: { try await firstNetwork.read($0) })
        let secondEngine = CompanionUIEngine(
            worker: secondWorker, endpoint: { URL(string: "http://fixture.invalid:4820")! },
            read: { try await secondNetwork.read($0) })
        let firstBridge = CompanionUIBridge(invoke: {
            try await firstEngine.execute($0, payload: $1)
        })
        let secondBridge = CompanionUIBridge(invoke: {
            try await secondEngine.execute($0, payload: $1)
        })
        let first = CompanionWorkspaceSession(remote: firstBridge)
        let second = CompanionWorkspaceSession(remote: secondBridge)
        let client = CompanionClient(
            baseURL: URL(string: "http://fixture.invalid:4820")!, transport: first.transport)
        let cleanup: @MainActor () async -> Void = {
            await first.cancelAndWait(); first.shutdown()
            await second.cancelAndWait(); second.shutdown()
            await firstBridge.stopAndWait(); await secondBridge.stopAndWait()
            await firstEngine.shutdown(); await secondEngine.shutdown()
            await firstWorker.shutdown(); await secondWorker.shutdown()
        }
        do {
            var finished = false
            let request = Task { () throws -> [String: String] in
                defer { finished = true }
                return try await client.get("episodes/synthetic/media")
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while await firstNetwork.count == 0, !finished, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(await firstNetwork.count == 1)
            await second.cancelAndWait()
            second.shutdown()
            await secondBridge.stopAndWait()
            #expect(!finished)
            #expect(await secondNetwork.count == 0)
            await firstNetwork.release()
            #expect(try await request.value == ["window": "first"])
            let media = try await client.media(episodeId: "synthetic")
            #expect(
                try JSONDecoder().decode([String: String].self, from: media.0) == [
                    "window": "first"
                ])
            #expect(await firstNetwork.count == 2)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test func presentationCloseCancelsBackendWorkBeforeInvalidatingTheClient() async throws {
        let network = WindowRequestFixture(name: "closing")
        let worker = CompanionWorker(transport: CompanionTransport())
        let engine = CompanionUIEngine(
            worker: worker, endpoint: { URL(string: "http://fixture.invalid:4820")! },
            read: { try await network.read($0) })
        let channel = WindowEngineFixture(engine: engine)
        let presentation = UUID()
        let client = try #require(
            ExtensionEngineClient(bridge: channel, presentationID: presentation))
        let runtime = ExtensionRuntime(fixtureAdmission: { _ in nil })
        let workspace = try #require(runtime.configureUI(client: client))
        #expect(CompanionTransport.shared.remoteBridge == nil)
        let request = Task {
            try await workspace.transport.data(
                for: URLRequest(
                    url: URL(string: "http://fixture.invalid/v1/episodes/synthetic/media")!))
        }
        let close: @MainActor () async -> NSString? = {
            await withCheckedContinuation { continuation in
                runtime.prepareUIToClose(presentation.uuidString as NSString) {
                    continuation.resume(returning: $0)
                }
            }
        }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while await network.count == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(await network.count == 1)
            #expect(await close() == nil)
            #expect(channel.operations.contains("companion.ui.cancel"))
            #expect(workspace.isStopped)
            let outcome = await request.result
            #expect(throws: (any Error).self) { try outcome.get() }
            await #expect(throws: ExtensionEngineError.unavailable) {
                try await client.invoke("companion.ui.upload")
            }
        } catch {
            _ = await close()
            await engine.shutdown(); await worker.shutdown()
            throw error
        }
        _ = runtime.execute(["operation": "stopUI"])
        await engine.shutdown(); await worker.shutdown()
    }

    @Test func closingAWorkspaceDoesNotStopAnotherOwnersGeneration() async {
        let bridge = CompanionUIBridge(invoke: { _, _ in Data() })
        let workspace = CompanionWorkspaceSession(remote: bridge)
        var foreignGenerationStopped = false
        let generation = CompanionGeneration.track { foreignGenerationStopped = true }
        defer { CompanionGeneration.forget(generation) }
        await workspace.cancelAndWait()
        workspace.shutdown()
        #expect(!foreignGenerationStopped)
        await bridge.stopAndWait()
    }
}

private actor WindowRequestFixture {
    let name: String
    private(set) var count = 0
    private var released = false
    private var waiting: CheckedContinuation<Void, Never>?

    init(name: String) { self.name = name }

    func read(_ request: URLRequest) async throws -> (Data, URLResponse) {
        count += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released { continuation.resume() } else { waiting = continuation }
            }
        } onCancel: {
            Task { await self.release() }
        }
        try Task.checkCancellation()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        return (try JSONEncoder().encode(["window": name]), response)
    }

    func release() {
        released = true
        waiting?.resume()
        waiting = nil
    }
}

@MainActor private final class WindowEngineFixture: NSObject {
    let engine: CompanionUIEngine
    private(set) var operations: [String] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(engine: CompanionUIEngine) { self.engine = engine }

    @objc func invoke(_ bytes: NSData, completion: @escaping (NSData) -> Void) {
        guard
            let request = try? ExtensionEngineWire.decode(
                ExtensionEngineRequest.self, from: bytes as Data)
        else {
            completion(Data() as NSData)
            return
        }
        operations.append(request.operation)
        tasks[request.token] = Task { [self] in
            defer { tasks[request.token] = nil }
            let reply: ExtensionEngineReply
            do {
                reply = ExtensionEngineReply(
                    token: request.token, ok: true,
                    payload: try await engine.execute(request.operation, payload: request.payload))
            } catch {
                reply = ExtensionEngineReply(token: request.token, ok: false)
            }
            completion(((try? ExtensionEngineWire.encode(reply)) ?? Data()) as NSData)
        }
    }

    @objc func cancel(_ value: NSString) {
        if let token = UUID(uuidString: value as String) { tasks[token]?.cancel() }
    }
}
