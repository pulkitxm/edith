import EdithExtensionSupport
import Foundation
import Testing
@testable import TerminalExtension

@MainActor private final class TerminalTestBridge: NSObject {
    let engine: TerminalEngine
    var holdSnapshots = false
    var held: [() -> Void] = []
    var cancelled: [UUID] = []
    var transform: ((Data) -> Data)?
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(engine: TerminalEngine) { self.engine = engine }

    @objc func invoke(_ bytes: NSData, completion: @escaping (NSData) -> Void) {
        guard
            let request = try? ExtensionEngineWire.decode(
                ExtensionEngineRequest.self, from: bytes as Data)
        else { Issue.record("Fixture bridge received invalid SDK wire data"); return }
        tasks[request.token] = Task {
            do {
                let value = try await engine.execute(request.operation, payload: request.payload)
                let reply = try ExtensionEngineWire.encode(
                    ExtensionEngineReply(
                        token: request.token, ok: true, payload: transform?(value) ?? value))
                let deliver = { completion(reply as NSData) }
                if holdSnapshots && request.operation == "terminal.snapshot" {
                    held.append(deliver)
                } else {
                    deliver()
                }
            } catch {
                if let reply = try? ExtensionEngineWire.encode(
                    ExtensionEngineReply(token: request.token, ok: false))
                {
                    completion(reply as NSData)
                }
            }
            tasks[request.token] = nil
        }
    }

    @objc func cancel(_ value: NSString) {
        guard let token = UUID(uuidString: value as String) else { return }
        cancelled.append(token)
        tasks[token]?.cancel()
        tasks[token] = nil
    }
}

@Suite(.serialized) @MainActor struct TerminalRemoteClientTests {
    private func engine() -> TerminalEngine {
        TerminalEngine {
            TerminalLaunch(
                executable: "/bin/cat", arguments: [], environment: [],
                currentDirectory: "/private/tmp", startupCommand: nil)
        }
    }

    private func facade(_ bridge: TerminalTestBridge) throws -> TerminalRemoteClient {
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        return TerminalRemoteClient(client: client)
    }

    @Test func facadeUsesRealEngineForTabsInputResizeOutputAndBroadcast() async throws {
        let engine = engine()
        defer { engine.stop() }
        let bridge = TerminalTestBridge(engine: engine)
        let remote = try facade(bridge)
        defer { remote.stop() }
        await remote.open()
        let session = try #require(remote.snapshot.sessions.first)
        try await remote.resize(session, columns: 120, rows: 40)
        try await remote.input(Data("owned-render-input".utf8), to: session)
        let first = try await remote.read(session, after: 0)
        #expect(String(decoding: first.bytes, as: UTF8.self) == "owned-render-input")
        let delivered = try await remote.broadcast("synthetic-broadcast")
        #expect(delivered.sent == 1 && delivered.unavailable == 0)
        let second = try await remote.read(session, after: first.nextOffset)
        #expect(String(decoding: second.bytes, as: UTF8.self) == "synthetic-broadcast\n")
        await remote.close(session)
        #expect(remote.snapshot.sessions.isEmpty)
        await #expect(throws: ExtensionEngineError.self) {
            try await remote.input(Data([65]), to: session)
        }
    }

    @Test func delayedOldSnapshotCannotOverwriteNewTabAndStopCancelsOwnedRead() async throws {
        let engine = engine()
        defer { engine.stop() }
        let bridge = TerminalTestBridge(engine: engine)
        let remote = try facade(bridge)
        await remote.open()
        bridge.holdSnapshots = true
        let stale = Task { await remote.refresh() }
        for _ in 0..<100 where bridge.held.isEmpty {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(bridge.held.count == 1)
        await remote.open()
        #expect(remote.snapshot.sessions.count == 2)
        bridge.held.forEach { $0() }
        bridge.held.removeAll()
        await stale.value
        #expect(remote.snapshot.sessions.count == 2)
        let selected = try #require(remote.snapshot.sessions.last)
        let pending = Task { try await remote.read(selected, after: 0) }
        try await Task.sleep(for: .milliseconds(20))
        remote.stop()
        remote.stop()
        await #expect(throws: (any Error).self) { try await pending.value }
        #expect(!bridge.cancelled.isEmpty && remote.snapshot.sessions.isEmpty)
        #expect(try engine.snapshot().sessions.count == 2)
    }

    @Test func preferencesRoundTripThroughTheOwnedEngineAndRejectInvalidValues() async throws {
        let suite = "terminal.remote.preferences." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = TerminalEngine(defaults: defaults)
        defer { engine.stop() }
        let bridge = TerminalTestBridge(engine: engine)
        let remote = try facade(bridge)
        defer { remote.stop() }
        let settings = TerminalSettings(fontSize: 17, shell: "/bin/sh", loginShell: false)
        #expect(try await remote.savePreferences(settings) == settings)
        #expect(try await remote.preferences() == settings)
        #expect(TerminalSettings.load(defaults) == settings)
        var invalid = settings
        invalid.shell = "bad\u{0}"
        await #expect(throws: (any Error).self) { try await remote.savePreferences(invalid) }
        #expect(TerminalSettings.load(defaults) == settings)
    }

    @Test func malformedEngineSnapshotIsRejectedAndRetainsLastValidContent() async throws {
        let engine = engine()
        defer { engine.stop() }
        let bridge = TerminalTestBridge(engine: engine)
        let remote = try facade(bridge)
        defer { remote.stop() }
        await remote.open()
        let previous = remote.snapshot
        bridge.transform = { _ in Data(#"{"sessions":[],"broadcast":"wrong"}"#.utf8) }
        await remote.refresh()
        #expect(remote.snapshot == previous && remote.error != nil)
        bridge.transform = nil
        await remote.refresh()
        #expect(remote.error == nil)
        let session = try #require(remote.snapshot.sessions.first)
        await remote.restart(session)
        await #expect(throws: ExtensionEngineError.self) {
            try await remote.read(session, after: 0)
        }
    }
}
