import Foundation
import Testing
@testable import TerminalExtension

private actor TerminalFileImportGate {
    private var entered: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var targets: [URL] = []

    func copy(_ source: URL, to target: URL) async throws {
        targets.append(target)
        for waiter in entered { waiter.resume() }
        entered.removeAll()
        if !released {
            await withCheckedContinuation { continuation = $0 }
        }
        try FileManager.default.copyItem(at: source, to: target)
    }

    func waitForCopy() async {
        guard targets.isEmpty else { return }
        await withCheckedContinuation { entered.append($0) }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@Suite(.serialized) @MainActor struct TerminalFileImportOwnershipTests {
    @Test func stopJoinsTheWholeImportBeforeReleasingItsDirectories() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let gate = TerminalFileImportGate()
        let files = TerminalEngineFiles(
            root: fixture.root, open: { _ in false }, handler: { _ in "Fixture handler" },
            copy: { try await gate.copy($0, to: $1) })
        let session = TerminalEngine.SessionRequest(id: UUID(), generation: UUID())
        var inputs: [Data] = []
        let operation = Task {
            try await files.execute(
                "terminal.drop.paths", payload: payload(fixture.sources, session: session),
                session: session, directory: fixture.root.path, input: { inputs.append($0) })
        }
        await gate.waitForCopy()
        let targets = await gate.targets
        let directory = try #require(targets.first).deletingLastPathComponent()
        files.stop()
        #expect(FileManager.default.fileExists(atPath: directory.path))
        var joined = false
        var stopping: Task<Void, Never>?
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            stopping = Task {
                started.resume()
                await files.stopAndWait()
                joined = true
            }
        }
        #expect(!joined)
        await gate.release()
        await stopping?.value
        #expect(joined)
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(await gate.targets.count == 1)
        #expect(inputs.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
        #expect(try Data(contentsOf: fixture.sources[0]) == Data("first synthetic file".utf8))
        #expect(try Data(contentsOf: fixture.sources[1]) == Data("second synthetic file".utf8))
    }

    @Test func sessionCloseCancelsOldImportAndPreservesReplacementUploads() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let gate = TerminalFileImportGate()
        let files = TerminalEngineFiles(
            root: fixture.root, open: { _ in false }, handler: { _ in "Fixture handler" },
            copy: { try await gate.copy($0, to: $1) })
        let session = TerminalEngine.SessionRequest(id: UUID(), generation: UUID())
        var inputs: [Data] = []
        let operation = Task {
            try await files.execute(
                "terminal.drop.paths", payload: payload(fixture.sources, session: session),
                session: session, directory: fixture.root.path, input: { inputs.append($0) })
        }
        await gate.waitForCopy()
        files.close(session.id)
        let replacement = TerminalEngine.SessionRequest(id: session.id, generation: UUID())
        let begin = TerminalEngineFiles.Begin(session: replacement, fileExtension: "txt")
        let data = try await files.execute(
            "terminal.drop.begin", payload: JSONEncoder().encode(begin), session: replacement,
            directory: fixture.root.path, input: { inputs.append($0) })
        let handle = try JSONDecoder().decode(TerminalEngineFiles.Handle.self, from: data)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await operation.value }
        let chunk = TerminalEngineFiles.Chunk(handle: handle, offset: 0, bytes: Data([65]))
        _ = try await files.execute(
            "terminal.drop.write", payload: JSONEncoder().encode(chunk), session: replacement,
            directory: fixture.root.path, input: { inputs.append($0) })
        await files.stopAndWait()
        #expect(await gate.targets.count == 1)
        #expect(inputs.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    }

    @Test func callerCancellationJoinsCopyAndReleasesPartialImport() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let gate = TerminalFileImportGate()
        let files = TerminalEngineFiles(
            root: fixture.root, open: { _ in false }, handler: { _ in "Fixture handler" },
            copy: { try await gate.copy($0, to: $1) })
        let session = TerminalEngine.SessionRequest(id: UUID(), generation: UUID())
        var inputs: [Data] = []
        let operation = Task {
            try await files.execute(
                "terminal.drop.paths", payload: payload(fixture.sources, session: session),
                session: session, directory: fixture.root.path, input: { inputs.append($0) })
        }
        await gate.waitForCopy()
        operation.cancel()
        let targets = await gate.targets
        let directory = try #require(targets.first).deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: directory.path))
        await gate.release()
        await #expect(throws: CancellationError.self) { try await operation.value }
        await files.stopAndWait()
        #expect(await gate.targets.count == 1)
        #expect(inputs.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    }

    private func makeFixture() throws -> (base: URL, root: URL, sources: [URL]) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "terminal-import-ownership-" + UUID().uuidString)
        let root = base.appendingPathComponent("uploads")
        let source = base.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let sources = [
            source.appendingPathComponent("first.txt"), source.appendingPathComponent("second.txt"),
        ]
        try Data("first synthetic file".utf8).write(to: sources[0])
        try Data("second synthetic file".utf8).write(to: sources[1])
        return (base, root, sources)
    }

    private func payload(_ sources: [URL], session: TerminalEngine.SessionRequest) throws -> Data {
        try JSONEncoder().encode(
            TerminalEngineFiles.Paths(
                session: session, items: sources.map { .init(path: $0.path, temporary: true) }))
    }
}
