import AppKit
import EdithExtensionSupport
import Foundation
import Testing

@testable import MachinesExtension

@Suite(.serialized) @MainActor struct MachineFilesEngineTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func presentationReleaseCancelsAndDrainsOriginalFileLoadProcess() async throws {
        let session = MachineSession(machine: .local, local: true, observesWakeRequests: false)
        let owner = MachineExecutionOwner()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        defer { if process.isRunning { process.terminate() } }
        let stream = SSHLineStream(process: process, onLine: { _, _ in }, onExit: { _ in })
        let files = MachineFilesEngine(
            session: { _ in session },
            makeModel: { session, path in
                FinderModel(
                    session: session, path: path,
                    directoryLoader: { _ in
                        do {
                            try owner.start(stream)
                            _ = await stream.waitForExit()
                            await stream.waitForProcessExit()
                            owner.release(stream)
                            return .failure(CancellationError())
                        } catch { return .failure(error) }
                    }, freeSpaceLoader: { _ in nil })
            })
        let engine = MachineUIEngine(
            session: { _ in session },
            state: {
                MachineUIState(
                    machines: [], forwards: [], snippets: [], sessions: [], workspaces: .init())
            }, mutation: { _ in }, workspace: { _ in }, files: { try await files.execute($0) },
            presentationRelease: { files.release($0) })
        let presentation = UUID()
        let request = MachineFileRequest(
            presentationID: presentation, viewID: UUID(), machineID: session.id,
            operation: .load, path: "/synthetic")
        let begin = try await engine.execute(
            "machines.ui.begin",
            payload: JSONEncoder().encode(
                MachineUIJobInput(
                    presentationID: presentation, operation: "machines.ui.files",
                    payload: JSONEncoder().encode(request))))
        let reply = try JSONDecoder().decode(MachineUIReply.self, from: begin)
        #expect(reply.error == nil)
        for _ in 0..<100 {
            if process.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(process.isRunning)
        _ = try await engine.execute(
            "machines.ui.release",
            payload: JSONEncoder().encode(MachineUIPresentation(id: presentation)))
        await engine.shutdown()
        await files.shutdownAndWait()
        #expect(!process.isRunning)
        await owner.shutdown()
        await session.shutdown()
    }

    @Test func originalTransfersExposeLiveProgressAndPresentationRelease() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"),
            target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let paths = try (0..<64).map { index in
            let path = source.appendingPathComponent("fixture-\(index).bin")
            try Data(repeating: UInt8(index), count: 131072).write(to: path)
            return path.path
        }
        let session = MachineSession(machine: .local, local: true, observesWakeRequests: false)
        let engine = MachineFilesEngine(session: { _ in session })
        let presentation = UUID()
        var request = MachineFileRequest(
            presentationID: presentation, viewID: UUID(), machineID: session.id, operation: .upload,
            path: target.path)
        request.paths = paths
        let task = Task { try await engine.execute(request) }
        var progress: FileOperationProgress?
        for _ in 0..<10000 {
            progress = try engine.progress(request)
            if progress != nil { break }
            await Task.yield()
        }
        #expect(progress != nil)
        #expect(progress?.total == 64)
        let state = try await task.value
        #expect(state.error == nil)
        #expect(state.entries.count == 64)
        #expect(
            try Data(contentsOf: target.appendingPathComponent("fixture-31.bin"))
                == Data(repeating: 31, count: 131072))
        engine.release(presentation)
        #expect(try engine.progress(request) == nil)
        engine.shutdown(); await session.shutdown()
    }

    @Test func originalFileRenameAndUndoRunInOwningEngine() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.txt")
        try Data("synthetic contents".utf8).write(to: original)
        let session = MachineSession(machine: .local, local: true, observesWakeRequests: false)
        let engine = MachineFilesEngine(session: { id in
            guard id == session.id else { throw MachineUIError.invalidRequest }
            return session
        })
        var request = MachineFileRequest(
            viewID: UUID(), machineID: session.id, operation: .load, path: root.path)
        let loaded = try await engine.execute(request)
        #expect(loaded.entries.map(\.name) == ["original.txt"])
        request.operation = .rename
        request.selection = [original.path]
        request.paths = [original.path]
        request.text = "renamed.txt"
        let renamed = try await engine.execute(request)
        #expect(renamed.error == nil)
        #expect(renamed.undoSteps.count == 1)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(
            try Data(contentsOf: root.appendingPathComponent("renamed.txt"))
                == Data("synthetic contents".utf8))
        request.operation = .undo
        let undone = try await engine.execute(request)
        #expect(undone.error == nil)
        #expect(undone.undoSteps.isEmpty)
        #expect(try Data(contentsOf: original) == Data("synthetic contents".utf8))
        #expect(
            !FileManager.default.fileExists(atPath: root.appendingPathComponent("renamed.txt").path)
        )
        engine.shutdown()
        await session.shutdown()
    }

    @Test func originalFolderAndDuplicateOperationsUseEngineFiles() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("sample.txt")
        try Data("synthetic duplicate".utf8).write(to: original)
        let session = MachineSession(machine: .local, local: true, observesWakeRequests: false)
        let engine = MachineFilesEngine(session: { _ in session })
        var request = MachineFileRequest(
            viewID: UUID(), machineID: session.id, operation: .load, path: root.path)
        _ = try await engine.execute(request)
        request.operation = .mkdir
        let folder = try await engine.execute(request)
        #expect(folder.entries.contains { $0.name == "untitled folder" && $0.isDirectory })
        request.operation = .duplicate
        request.paths = [original.path]
        let duplicated = try await engine.execute(request)
        #expect(duplicated.error == nil)
        let copy = try #require(
            duplicated.entries.first { $0.path != original.path && !$0.isDirectory })
        #expect(
            try Data(contentsOf: URL(fileURLWithPath: copy.path))
                == Data("synthetic duplicate".utf8))
        engine.shutdown()
        await #expect(throws: MachineUIError.unavailable) { try await engine.execute(request) }
        await session.shutdown()
    }

    @Test func fileViewCannotSwitchMachineOwnership() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = MachineSession(machine: .local, local: true, observesWakeRequests: false)
        let engine = MachineFilesEngine(session: { _ in session })
        var request = MachineFileRequest(
            viewID: UUID(), machineID: session.id, operation: .load, path: root.path)
        _ = try await engine.execute(request)
        request.machineID = UUID()
        await #expect(throws: MachineUIError.invalidRequest) { try await engine.execute(request) }
        engine.shutdown()
        await session.shutdown()
    }

    @Test func previewReadsBoundedChunksAndRejectsStaleOffsets() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data((0..<150_000).map { UInt8($0 % 251) })
        let file = root.appendingPathComponent("preview.dat")
        try bytes.write(to: file)
        let session = MachineSession(machine: .local, local: true, observesWakeRequests: false)
        let engine = MachinePreviewEngine(session: { _ in session })
        let entry = RemoteFileEntry(
            name: file.lastPathComponent, path: file.path, kind: .file,
            sizeBytes: Int64(bytes.count))
        let prepared = try await engine.execute(
            MachinePreviewRequest(operation: .prepare, machineID: session.id, entry: entry))
        let handle = try JSONDecoder().decode(MachinePreviewHandle.self, from: prepared)
        #expect(handle.count == UInt64(bytes.count))
        var read = MachinePreviewRequest(operation: .read, machineID: session.id, id: handle.id)
        var captured = Data()
        while true {
            let result = try await engine.execute(read)
            let chunk = try JSONDecoder().decode(MachinePreviewChunk.self, from: result)
            #expect(chunk.bytes.count <= 65_536)
            captured.append(chunk.bytes)
            if chunk.complete { break }
            await #expect(throws: MachineUIError.invalidRequest) { try await engine.execute(read) }
            read.offset += UInt64(chunk.bytes.count)
        }
        #expect(captured == bytes)
        await #expect(throws: MachineUIError.invalidRequest) { try await engine.execute(read) }
        engine.shutdown()
        await session.shutdown()
    }
}
