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

    @Test func disablingRuntimeAwaitsActiveStreamExportAndPreservesExistingFiles() async throws {
        let runtime = ExtensionRuntime()
        let suite = try #require(ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"])
        let started = runtime.execute(
            ["operation": "start", "defaultsSuite": suite] as NSDictionary)
        #expect((started as? NSDictionary)?["ok"] as? Bool == true)
        let root = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = try await VideoEditorServiceTests.movie(in: root)
        var project = VideoProject.create()
        project.videoSettings = VideoSettings(width: 320, height: 180, frameRateNumerator: 30)
        project.addAsset(movie, duration: 1, width: 64, height: 64)
        let clip = try #require(project.clips.first?.id)
        for _ in 0..<119 { _ = project.duplicate(clipID: clip) }
        let source = root.appendingPathComponent("disable.openscreen")
        try project.save(to: source)
        let originalSource = try Data(contentsOf: source)
        let output = root.appendingPathComponent("preserved.mp4")
        let originalOutput = Data("Synthetic existing output".utf8)
        try originalOutput.write(to: output)
        let request = try ExtensionCLIRequest(
            arguments: [
                "edit", "render", "disable.openscreen", "--output", "preserved.mp4",
                "--overwrite", "--progress", "--json",
            ], workingDirectory: root.path)
        let (bytes, failure) = await invoke(
            runtime, command: "studio.cli.start",
            payload: try JSONEncoder().encode(
                ExtensionCLIStreamStart(
                    owner: "studio", session: UUID(), request: request)))
        #expect(failure == nil)
        let handle = try JSONDecoder().decode(ExtensionCLIStreamHandle.self, from: #require(bytes))
        var sequence: UInt64 = 0
        var stderr = Data()
        var hasProgress = false
        let deadline = ContinuousClock.now + .seconds(15)
        while !hasProgress, ContinuousClock.now < deadline {
            let (data, error) = await invoke(
                runtime, command: "studio.cli.read",
                payload: try JSONEncoder().encode(
                    ExtensionCLIStreamRead(handle: handle, sequence: sequence)))
            #expect(error == nil)
            let frame = try JSONDecoder().decode(ExtensionCLIStreamFrame.self, from: #require(data))
            try frame.validate()
            #expect(frame.sequence == sequence && frame.state == .running)
            for chunk in frame.chunks where chunk.channel == .stderr { stderr.append(chunk.data) }
            sequence = frame.nextSequence
            hasProgress = String(decoding: stderr, as: UTF8.self).split(separator: "\n").contains {
                line in
                guard
                    let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                        as? [String: Any],
                    let percent = object["percent"] as? Int
                else { return false }
                return percent > 0 && percent < 100
            }
            if !hasProgress { try await Task.sleep(for: .milliseconds(5)) }
        }
        try #require(hasProgress)
        let stopped = ContinuousClock.now
        await withCheckedContinuation { continuation in
            runtime.prepareToStop { continuation.resume() }
        }
        #expect(stopped.duration(to: .now) < .seconds(5))
        let status = runtime.execute(["operation": "status"] as NSDictionary) as? NSDictionary
        #expect(status?["running"] as? Bool == false && status?["preventsQuit"] as? Bool == false)
        #expect(
            try Data(contentsOf: source) == originalSource
                && Data(contentsOf: output) == originalOutput)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy {
                !$0.hasPrefix(".studio-video-")
            })
        let (lateData, lateFailure) = await invoke(
            runtime, command: "studio.cli.read",
            payload: try JSONEncoder().encode(
                ExtensionCLIStreamRead(handle: handle, sequence: sequence)))
        #expect(lateData == nil && lateFailure != nil)
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
