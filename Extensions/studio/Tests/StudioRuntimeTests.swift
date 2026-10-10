import EdithExtensionSupport
import EdithStudio
import Foundation
import Testing
@testable import StudioExtension

@MainActor @Suite(.serialized) struct StudioRuntimeTests {
    private func invoke(_ runtime: ExtensionRuntime, command: String, payload: Data) async
        -> (Data?, String?)
    {
        await withCheckedContinuation { continuation in
            runtime.invoke(
                ["token": UUID().uuidString, "command": command, "payload": payload] as NSDictionary
            ) { bytes, failure in
                continuation.resume(
                    returning: (bytes.map { $0 as Data }, failure.map { $0 as String }))
            }
        }
    }

    @Test func ownedRuntimeInvokesOriginalCLIAndRejectsAfterDisable() async throws {
        let runtime = ExtensionRuntime()
        let suite = try #require(ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"])
        let started = runtime.execute(
            ["operation": "start", "defaultsSuite": suite] as NSDictionary)
        #expect((started as? NSDictionary)?["ok"] as? Bool == true)
        let request = try ExtensionCLIRequest(
            arguments: ["info", "nonexistent.tool"], workingDirectory: "/tmp")
        let (bytes, failure) = await invoke(
            runtime, command: "studio.cli", payload: try JSONEncoder().encode(request))
        #expect(failure == nil)
        let reply = try JSONDecoder().decode(ExtensionCLIReply.self, from: #require(bytes))
        #expect(reply.exitCode == 3 && reply.stdout.isEmpty)
        #expect(reply.stderr.contains("no Studio tool called nonexistent.tool"))
        await withCheckedContinuation { continuation in
            runtime.prepareToStop { continuation.resume() }
        }
        let status = runtime.execute(["operation": "status"] as NSDictionary)
        #expect((status as? NSDictionary)?["running"] as? Bool == false)
        let (disabledBytes, disabledFailure) = await invoke(
            runtime, command: "studio.cli", payload: try JSONEncoder().encode(request))
        #expect(disabledBytes == nil && disabledFailure != nil)
    }

    @Test func streamedNativeExportDrainsOrderedOutputBeforeCompletion() async throws {
        let runtime = ExtensionRuntime()
        let suite = try #require(ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"])
        _ = runtime.execute(["operation": "start", "defaultsSuite": suite] as NSDictionary)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "studio-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = try await VideoEditorServiceTests.movie(in: root)
        let project = root.appendingPathComponent("stream.openscreen")
        _ = try VideoEditorService.create(at: project, title: "Synthetic stream")
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [.addMedia(path: movie.path, name: "source")]),
            to: project, overwrite: true)
        let request = try ExtensionCLIRequest(
            arguments: [
                "edit", "render", "stream.openscreen", "--output", "stream.mp4",
                "--progress", "--json",
            ], workingDirectory: root.path)
        let start = ExtensionCLIStreamStart(owner: "studio", session: UUID(), request: request)
        let (bytes, error) = await invoke(
            runtime, command: "studio.cli.start", payload: try JSONEncoder().encode(start))
        #expect(error == nil)
        let handle = try JSONDecoder().decode(ExtensionCLIStreamHandle.self, from: #require(bytes))
        var sequence: UInt64 = 0
        var stdout = Data()
        var stderr = Data()
        var sawLiveProgress = false
        var exitCode: Int32?
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            let (data, failure) = await invoke(
                runtime, command: "studio.cli.read",
                payload: try JSONEncoder().encode(
                    ExtensionCLIStreamRead(handle: handle, sequence: sequence)))
            #expect(failure == nil)
            let frame = try JSONDecoder().decode(ExtensionCLIStreamFrame.self, from: #require(data))
            try frame.validate()
            #expect(frame.sequence == sequence)
            for chunk in frame.chunks {
                #expect(chunk.sequence == sequence)
                sequence += 1
                if chunk.channel == .stdout {
                    stdout.append(chunk.data)
                } else {
                    stderr.append(chunk.data)
                }
            }
            #expect(sequence == frame.nextSequence)
            if frame.state == .running, !stderr.isEmpty { sawLiveProgress = true }
            if frame.state != .running { exitCode = frame.exitCode; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(exitCode == 0 && sawLiveProgress)
        #expect(String(decoding: stderr, as: UTF8.self).contains("\"percent\":100"))
        let result = try JSONDecoder().decode(VideoEditorService.Result.self, from: stdout)
        #expect(result.written && (result.videoReport?.bytes ?? 0) > 0)
        let (_, endError) = await invoke(
            runtime, command: "studio.cli.end",
            payload: try JSONEncoder().encode(handle))
        #expect(endError == nil)
        await withCheckedContinuation { continuation in
            runtime.prepareToStop { continuation.resume() }
        }
    }

    @Test func remoteUIContextCannotStartOwnedNativeServices() throws {
        let runtime = ExtensionRuntime()
        let suite = try #require(ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"])
        let result = runtime.execute(
            ["operation": "start", "remoteUI": true, "defaultsSuite": suite]
                as NSDictionary)
        #expect((result as? NSDictionary)?["ok"] as? Bool == false)
        let status = runtime.execute(["operation": "status"] as NSDictionary)
        #expect((status as? NSDictionary)?["running"] as? Bool == false)
    }
}
