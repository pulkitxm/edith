import Foundation
import GhosttyTerminal
import Testing
@testable import TerminalExtension

@Suite(.serialized) @MainActor struct TerminalEngineFileTests {
    @Test func originalMediaAndPromisedFoldersBecomeOwnedFilesAndPTYInput() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(
            "terminal-files-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = TerminalEngineFiles(
            root: root,
            open: { _ in
                Issue.record("Unexpected URL open"); return false
            }, handler: { _ in "Fixture handler" })
        let engine = TerminalEngine(
            launch: {
                TerminalLaunch(
                    executable: "/bin/cat", arguments: [], environment: [],
                    currentDirectory: "/private/tmp", startupCommand: nil)
            }, files: files)
        defer { engine.stop() }
        let remote = try TerminalTestFixture.remote(engine)
        defer { remote.stop() }
        await remote.open()
        let session = try #require(remote.snapshot.sessions.first)
        let media = Data(repeating: 0x52, count: 40_000)
        try await remote.importDrop(
            TerminalDropPayload(
                files: [], media: TerminalDropMedia(data: media, fileExtension: "png")), to: session
        )
        let directories = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
        let uploaded = try #require(directories.first).appendingPathComponent("drop.png")
        #expect(try Data(contentsOf: uploaded) == media)
        let first = try await remote.read(session, after: 0)
        #expect(
            String(decoding: first.bytes, as: UTF8.self)
                == GhosttyTerminalView.quotePath(uploaded.path))
        let source = root.appendingPathComponent("promised folder")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("synthetic document".utf8).write(to: source.appendingPathComponent("document.txt"))
        try await remote.importDrop(
            TerminalDropPayload(files: [source], temporaryFiles: [source]), to: session)
        try FileManager.default.removeItem(at: source)
        let second = try await remote.read(session, after: first.nextOffset)
        let quoted = String(decoding: second.bytes, as: UTF8.self)
        #expect(quoted.hasPrefix("'") && quoted.hasSuffix("'"))
        let copied = URL(fileURLWithPath: String(quoted.dropFirst().dropLast()))
        #expect(
            try String(contentsOf: copied.appendingPathComponent("document.txt"), encoding: .utf8)
                == "synthetic document")
        await remote.restart(session)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func originalLinkPolicyUsesOwnedSingleUseReceiptsAndDisableReleasesUploads() async throws
    {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(
            "terminal-links-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var opened: [URL] = []
        let files = TerminalEngineFiles(
            root: root,
            open: {
                opened.append($0); return true
            }, handler: { _ in "Fixture handler" })
        let engine = TerminalEngine(
            launch: {
                TerminalLaunch(
                    executable: "/bin/cat", arguments: [], environment: [],
                    currentDirectory: root.path, startupCommand: nil)
            }, files: files)
        defer { engine.stop() }
        let remote = try TerminalTestFixture.remote(engine)
        defer { remote.stop() }
        await remote.open()
        let session = try #require(remote.snapshot.sessions.first)
        let allowed = try await remote.resolveLink(
            "https://example.com/fixture", untrusted: true, session: session)
        #expect(allowed.resolution.disposition == .allow && opened.isEmpty)
        let token = try #require(allowed.token)
        try await remote.openLink(token, session: session)
        #expect(opened.map(\.absoluteString) == ["https://example.com/fixture"])
        await #expect(throws: (any Error).self) {
            try await remote.openLink(token, session: session)
        }
        let denied = try await remote.resolveLink(
            "javascript:unsafe", untrusted: true, session: session)
        #expect(denied.resolution.disposition == .confirm && denied.token != nil)
        let malformed = try await remote.resolveLink(
            "https://example.com/\nunsafe", untrusted: true, session: session)
        #expect(malformed.resolution.disposition == .deny && malformed.token == nil)
        let request = TerminalEngineFiles.Begin(
            session: .init(id: session.id, generation: session.generation), fileExtension: "pdf")
        _ = try await engine.execute("terminal.drop.begin", payload: JSONEncoder().encode(request))
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty))
        engine.stop()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(opened.count == 1)
    }

    @Test func failedImportsReleasePartialFilesAndRestartRejectsOldUploadHandles() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(
            "terminal-failed-drop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.txt")
        try Data("synthetic".utf8).write(to: source)
        let engine = TerminalEngine(
            launch: {
                TerminalLaunch(
                    executable: "/bin/cat", arguments: [], environment: [],
                    currentDirectory: root.path, startupCommand: nil)
            },
            files: TerminalEngineFiles(
                root: root, open: { _ in false }, handler: { _ in "Fixture handler" }))
        defer { engine.stop() }
        let remote = try TerminalTestFixture.remote(engine)
        defer { remote.stop() }
        await remote.open()
        let session = try #require(remote.snapshot.sessions.first)
        let missing = root.appendingPathComponent("missing.txt")
        await #expect(throws: (any Error).self) {
            try await remote.importDrop(
                TerminalDropPayload(files: [source, missing], temporaryFiles: [source, missing]),
                to: session)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["fixture.txt"])
        let begin = TerminalEngineFiles.Begin(
            session: .init(id: session.id, generation: session.generation), fileExtension: "png")
        let data = try await engine.execute(
            "terminal.drop.begin", payload: JSONEncoder().encode(begin))
        let handle = try JSONDecoder().decode(TerminalEngineFiles.Handle.self, from: data)
        let chunk = TerminalEngineFiles.Chunk(handle: handle, offset: 1, bytes: Data([65]))
        await #expect(throws: (any Error).self) {
            try await engine.execute("terminal.drop.write", payload: JSONEncoder().encode(chunk))
        }
        await remote.restart(session)
        await #expect(throws: (any Error).self) {
            try await engine.execute("terminal.drop.finish", payload: JSONEncoder().encode(handle))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["fixture.txt"])
        #expect(try Data(contentsOf: source) == Data("synthetic".utf8))
    }
}
