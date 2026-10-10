import Darwin
import EdithExtensionSupport
import Foundation
import Testing
@testable import HerdrUI

@MainActor @Suite(.serialized) struct OwnedEngineRequestsTests {
    @Test func actualSDKQueuesTwelvePTYReadersAndReservesInputResizeAndUIControls() async throws {
        let registry = OwnedTerminalSessionRegistry()
        defer { registry.stopAll() }
        let sessions = try (0..<12).map { _ in
            try OwnedTerminalContext.$registry.withValue(registry) {
                try OwnedTerminalSession(
                    launch: .init(
                        executable: "/bin/sh",
                        arguments: [
                            "-c",
                            "stty icanon -echo; read value; printf '%s ☃:' \"$value\"; stty size; exit 7",
                        ],
                        environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color"],
                        currentDirectory: "/private/tmp", allowsLocalFileLinks: true,
                        resetTerminalAfterInterrupt: false))
            }
        }
        let bridge = SyntheticPTYEngineBridge(registry: registry)
        let sdk = try #require(
            ExtensionEngineClient(bridge: bridge, presentationID: bridge.presentation))
        defer { sdk.invalidate() }
        let ui = HerdrUIClient(client: sdk)
        defer { ui.stop() }
        let clients = try sessions.map { session in
            try OwnedTerminalClient(descriptor: session.descriptor) { operation, payload in
                try await ui.perform(operation, payload: payload)
            }
        }
        defer { clients.forEach { $0.stop() } }
        let reads = clients.map { client in Task { try await client.read(after: 0) } }
        defer { reads.forEach { $0.cancel() } }
        let deadline = ContinuousClock.now + .seconds(3)
        while bridge.reads < 4 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(bridge.reads == 4 && bridge.maximumReads == 4)
        reads[11].cancel()
        await #expect(throws: CancellationError.self) { try await reads[11].value }
        try await clients[0].resize(columns: 101, rows: 37)
        try await clients[0].input(Data("fixture-input\n".utf8))
        var bytes = Data()
        var offset: UInt64 = 0
        var exit: Int32?
        for (index, read) in reads.dropLast().enumerated() {
            let output = try await read.value
            if index == 0 {
                bytes.append(output.bytes)
                offset = output.nextOffset
                exit = output.exitCode
            }
        }
        for _ in 0..<20 where exit == nil {
            let output = try await clients[0].read(after: offset)
            bytes.append(output.bytes)
            offset = output.nextOffset
            exit = output.exitCode
        }
        #expect(exit == 7)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.contains("fixture-input ☃:") && text.contains("37 101"))
        #expect(bridge.maximumReads <= 4 && bridge.maximumRequests <= 8)
        #expect(bridge.sessionsSeen.contains(sessions[0].descriptor.handle.id))
        #expect(!bridge.sessionsSeen.contains(sessions[11].descriptor.handle.id))
        #expect(bridge.controls == ["herdr.terminal.resize", "herdr.terminal.input"])
    }

    @Test func stoppingOwnerQueueCancelsUnadmittedActualSDKRequests() async throws {
        let registry = OwnedTerminalSessionRegistry()
        defer { registry.stopAll() }
        let session = try OwnedTerminalContext.$registry.withValue(registry) {
            try OwnedTerminalSession(
                launch: .init(
                    executable: "/bin/sh", arguments: ["-c", "exec sleep 30"],
                    environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color"],
                    currentDirectory: "/private/tmp", allowsLocalFileLinks: true,
                    resetTerminalAfterInterrupt: false))
        }
        let bridge = SyntheticPTYEngineBridge(registry: registry)
        let sdk = try #require(
            ExtensionEngineClient(bridge: bridge, presentationID: bridge.presentation))
        defer { sdk.invalidate() }
        let requests = OwnedEngineRequests { operation, payload in
            try await sdk.invoke(operation, payload: payload)
        }
        let payload = try JSONEncoder().encode(
            OwnedTerminalRequest(session: session.descriptor.handle, offset: 0))
        let tasks = (0..<12).map { _ in
            Task { try await requests.perform("herdr.terminal.read", payload: payload) }
        }
        defer { tasks.forEach { $0.cancel() } }
        let deadline = ContinuousClock.now + .seconds(3)
        while bridge.reads < 4 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(bridge.reads == 4)
        requests.stop()
        tasks.forEach { $0.cancel() }
        for task in tasks { await #expect(throws: (any Error).self) { try await task.value } }
        #expect(bridge.totalRequests == 4)
        await #expect(throws: ExtensionPeerError.self) {
            try await requests.perform("herdr.terminal.read", payload: payload)
        }
    }
}

@MainActor final class SyntheticPTYEngineBridge: NSObject {
    let presentation = UUID()
    private let registry: OwnedTerminalSessionRegistry
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private(set) var reads = 0
    private(set) var maximumReads = 0
    private(set) var maximumRequests = 0
    private(set) var totalRequests = 0
    private(set) var sessionsSeen: Set<UUID> = []
    private(set) var controls: [String] = []

    init(registry: OwnedTerminalSessionRegistry) { self.registry = registry }

    @objc(invoke:completion:) func invoke(
        _ bytes: NSData, completion: @escaping @convention(block) (NSData) -> Void
    ) {
        guard
            let request = try? ExtensionEngineWire.decode(
                ExtensionEngineRequest.self, from: bytes as Data)
        else { return }
        let read = request.operation == "herdr.terminal.read"
        if read {
            reads += 1; maximumReads = max(maximumReads, reads)
        } else {
            controls.append(request.operation)
        }
        totalRequests += 1
        maximumRequests = max(maximumRequests, tasks.count + 1)
        tasks[request.token] = Task {
            defer { tasks[request.token] = nil; if read { reads -= 1 } }
            do {
                try request.validate()
                guard request.presentationID == presentation else {
                    throw ExtensionEngineError.rejected
                }
                let terminal = try JSONDecoder().decode(
                    OwnedTerminalRequest.self, from: request.payload)
                let session = try #require(registry.find(terminal.session))
                sessionsSeen.insert(terminal.session.id)
                let output = try await session.execute(request.operation, payload: request.payload)
                try Task.checkCancellation()
                completion(
                    try ExtensionEngineWire.encode(
                        ExtensionEngineReply(token: request.token, ok: true, payload: output))
                        as NSData)
            } catch {
                let reply = ExtensionEngineReply(token: request.token, ok: false)
                if let data = try? ExtensionEngineWire.encode(reply) { completion(data as NSData) }
            }
        }
    }

    @objc(cancel:) func cancel(_ token: NSString) {
        guard let id = UUID(uuidString: token as String) else { return }
        tasks[id]?.cancel()
    }
}
