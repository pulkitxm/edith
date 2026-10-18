import EdithExtensionSupport
import Foundation
import Testing
@testable import TerminalExtension

@Suite(.serialized) @MainActor struct TerminalEngineTests {
    private func engine(_ command: String = "exec cat") -> TerminalEngine {
        TerminalEngine {
            TerminalLaunch(
                executable: "/bin/sh", arguments: ["-c", command],
                environment: ["PATH=/usr/bin:/bin"], currentDirectory: "/private/tmp",
                startupCommand: nil)
        }
    }

    private func send<T: Encodable>(_ command: String, _ value: T, to engine: TerminalEngine)
        async throws -> Data
    {
        try await engine.execute(command, payload: JSONEncoder().encode(value))
    }

    private func open(_ engine: TerminalEngine) async throws -> TerminalEngine.SessionRequest {
        _ = try await engine.execute("terminal.open", payload: Data())
        let session = try #require(try engine.snapshot().sessions.last)
        return TerminalEngine.SessionRequest(id: session.id, generation: session.generation)
    }

    @Test func opensRealShellAndForwardsInputAndOutputWithoutAView() async throws {
        let engine = engine("read value; printf 'engine:%s' \"$value\"; exit 9")
        defer { engine.stop() }
        let session = try await open(engine)
        _ = try await send(
            "terminal.resize",
            TerminalEngine.ResizeRequest(session: session, columns: 90, rows: 30),
            to: engine)
        _ = try await send(
            "terminal.input",
            TerminalEngine.InputRequest(session: session, bytes: Data("mock\n".utf8)),
            to: engine)
        var output = Data()
        var offset: UInt64 = 0
        var code: Int32?
        for _ in 0..<20 {
            let response = try await send(
                "terminal.read", TerminalEngine.ReadRequest(session: session, offset: offset),
                to: engine)
            let read = try JSONDecoder().decode(TerminalPTY.Output.self, from: response)
            output.append(read.bytes)
            offset = read.nextOffset
            code = read.exitCode
            if code != nil { break }
        }
        #expect(String(decoding: output, as: UTF8.self) == "engine:mock")
        #expect(code == 9)
        #expect(try engine.snapshot().sessions.first?.running == false)
    }

    @Test func restartRejectsPreviousGenerationAndDisableCancelsPendingReads() async throws {
        let engine = engine()
        defer { engine.stop() }
        let previous = try await open(engine)
        _ = try await send("terminal.restart", previous, to: engine)
        await #expect(throws: ExtensionPeerError.self) {
            try await send(
                "terminal.input", TerminalEngine.InputRequest(session: previous, bytes: Data([65])),
                to: engine)
        }
        let current = try #require(try engine.snapshot().sessions.first)
        #expect(previous.id == current.id && previous.generation != current.generation)
        let request = TerminalEngine.ReadRequest(
            session: .init(id: current.id, generation: current.generation), offset: 0)
        let pending = Task { try await send("terminal.read", request, to: engine) }
        try await Task.sleep(for: .milliseconds(20))
        engine.stop()
        engine.stop()
        await #expect(throws: ExtensionPeerError.self) { try await pending.value }
        #expect(throws: ExtensionPeerError.self) { try engine.snapshot() }
    }

    @Test func cancelledReadsDoNotConsumeBytesOrCloseTheSession() async throws {
        let engine = engine()
        defer { engine.stop() }
        let session = try await open(engine)
        let request = TerminalEngine.ReadRequest(session: session, offset: 0)
        let pending = Task { try await send("terminal.read", request, to: engine) }
        try await Task.sleep(for: .milliseconds(20))
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        _ = try await send(
            "terminal.input",
            TerminalEngine.InputRequest(session: session, bytes: Data("kept".utf8)),
            to: engine)
        let bytes = try await send("terminal.read", request, to: engine)
        let output = try JSONDecoder().decode(TerminalPTY.Output.self, from: bytes)
        #expect(String(decoding: output.bytes, as: UTF8.self) == "kept")
        #expect(try engine.snapshot().sessions.first?.running == true)
    }

    @Test func enginePersistsOnlyOwnedTerminalPreferencesInAnIsolatedSuite() async throws {
        let suite = "terminal.engine.fixture." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("retained", forKey: "unrelatedFixtureKey")
        let engine = TerminalEngine(defaults: defaults) {
            TerminalLaunchPlan.make(
                settings: .load(defaults), base: ["HOME": "/private/tmp", "PATH": "/usr/bin:/bin"],
                home: "/private/tmp")
        }
        defer { engine.stop() }
        let settings = TerminalSettings(
            fontSize: 18, shell: "/bin/sh", loginShell: false, startFolder: .custom,
            customFolder: "/private/tmp", startupCommand: "printf synthetic", confirmClose: false)
        let saved = try await send("terminal.savePreferences", settings, to: engine)
        #expect(try JSONDecoder().decode(TerminalSettings.self, from: saved) == settings)
        #expect(TerminalSettings.load(defaults) == settings)
        #expect(defaults.string(forKey: "unrelatedFixtureKey") == "retained")
        var invalid = settings
        invalid.startupCommand = "bad\u{0}"
        await #expect(throws: (any Error).self) {
            try await send("terminal.savePreferences", invalid, to: engine)
        }
        #expect(TerminalSettings.load(defaults) == settings)
        _ = try await open(engine)
        let session = try #require(try engine.snapshot().sessions.first)
        var offset: UInt64 = 0
        var output = Data()
        for _ in 0..<20 {
            let bytes = try await send(
                "terminal.read",
                TerminalEngine.ReadRequest(
                    session: .init(id: session.id, generation: session.generation), offset: offset),
                to: engine)
            let response = try JSONDecoder().decode(TerminalPTY.Output.self, from: bytes)
            offset = response.nextOffset
            output.append(response.bytes)
            if String(decoding: output, as: UTF8.self).contains("synthetic") { break }
        }
        #expect(String(decoding: output, as: UTF8.self).contains("synthetic"))
    }

    @Test func retainedEngineDrainsBackgroundOutputWithoutAnyUIReads() async throws {
        let marker = URL(fileURLWithPath: "/tmp/terminal-engine-marker-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let engine = engine("head -c 400000 /dev/zero; printf done > '\(marker.path)'")
        defer { engine.stop() }
        let session = try await open(engine)
        for _ in 0..<1000 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "done")
        await #expect(throws: POSIXError.self) {
            try await send(
                "terminal.read", TerminalEngine.ReadRequest(session: session, offset: 0),
                to: engine)
        }
    }

    @Test func fixedOperationsRejectForeignSessionsInvalidPayloadsAndArbitraryLaunches()
        async throws
    {
        let engine = engine()
        defer { engine.stop() }
        _ = try await open(engine)
        let foreign = TerminalEngine.SessionRequest(id: UUID(), generation: UUID())
        await #expect(throws: ExtensionPeerError.self) {
            try await send("terminal.close", foreign, to: engine)
        }
        for (command, payload) in [
            ("machines.exec", Data()), ("terminal.open", Data("{\"executable\":\"/bin/sh\"}".utf8)),
            ("terminal.input", Data(repeating: 0, count: 32_769)),
        ] {
            await #expect(throws: ExtensionPeerError.self) {
                try await engine.execute(command, payload: payload)
            }
        }
        #expect(try engine.snapshot().sessions.count == 1)
    }
}
