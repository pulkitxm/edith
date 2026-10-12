import EdithExtensionSupport
import Foundation
import Testing
@testable import TimeLapseExtension

@Suite(.serialized) @MainActor struct TimeLapseRemoteUITests {
    @Test func originalRecorderStateKeepsUnsavedDraftAndUIShutdownDoesNotStopEngineRecording()
        async throws
    {
        guard #available(macOS 15.0, *) else { return }
        let owner = TimeLapseRecorder()
        owner.settings.frameRate = 30; owner.selectedDisplays = [42]
        let commands = TimeLapseUICommands(recorder: owner)
        let bridge = Bridge(commands: commands)
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        let remote = TimeLapseRecorder(engineClient: client)
        await remote.refreshRemote()
        #expect(remote.settings.frameRate == 30 && remote.selectedDisplays == [42])
        remote.settings.frameRate = 60
        await remote.refreshRemote()
        #expect(remote.settings.frameRate == 60 && owner.settings.frameRate == 30)
        owner.recording = true
        await remote.refreshRemote()
        #expect(remote.recording && remote.settings.frameRate == 30)
        await remote.shutdown(); client.invalidate()
        #expect(
            owner.recording && !bridge.operations.contains("recording.ui.stop")
                && !bridge.operations.contains("recording.ui.start"))
        await commands.shutdownAndWait()
        owner.recording = false; await owner.shutdown()
    }
    @Test func boundedSavedRecordingUsesOriginalRemoteExportAndExactQualityAndLeaf() async throws {
        guard #available(macOS 15.0, *) else {
            Issue.record("Saved recording export checks require macOS 15 or later.")
            return
        }
        let probe = try SavedExportProbe()
        let owner = TimeLapseRecorder(exportLibrary: try probe.library())
        let commands = TimeLapseUICommands(recorder: owner)
        let bridge = Bridge(commands: commands)
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        let remote = TimeLapseRecorder(engineClient: client)
        await remote.library.refresh()
        let recording = try #require(remote.library.recordings.first)
        #expect(recording.id == probe.scope.sessionID)
        #expect(recording.directory == probe.scope.directory)
        remote.library.export(recording, quality: .original, to: probe.scope.destination)
        await probe.waitForStart()
        #expect(probe.exports == 1 && probe.quality == .original)
        #expect(probe.destination == probe.scope.destination)
        #expect(probe.destination?.lastPathComponent == "Recording.mp4")
        #expect(remote.library.exporting)
        probe.release()
        await remote.library.finishExport()
        #expect(remote.library.message == "Saved Recording.mp4.")
        #expect(remote.library.exportLoad.errorMessage == nil)
        #expect(bridge.operations.contains("recording.ui.exportPoll"))
        let badToken = try JSONEncoder().encode(["token": UUID()])
        await #expect(throws: (any Error).self) {
            try await commands.execute("recording.ui.exportPoll", payload: badToken)
        }
        #expect(throws: TimeLapseError.self) {
            try probe.scope.requireExport(recording, quality: .high, to: probe.scope.destination)
        }
        #expect(throws: TimeLapseError.self) {
            try probe.scope.requireExport(
                recording, quality: .original,
                to: probe.scope.destination.deletingLastPathComponent()
                    .appendingPathComponent("Other.mp4"))
        }
        probe.current = false
        await #expect(throws: (any Error).self) {
            try await commands.execute("recording.ui.library", payload: Data("{}".utf8))
        }
        await remote.shutdown()
        client.invalidate()
        await commands.shutdownAndWait()
        await owner.shutdown()
    }

    @Test func originalRemoteCancelWaitsForSavedExporterCallbackReturn() async throws {
        guard #available(macOS 15.0, *) else {
            Issue.record("Saved recording export checks require macOS 15 or later.")
            return
        }
        let probe = try SavedExportProbe()
        let owner = TimeLapseRecorder(exportLibrary: try probe.library())
        let commands = TimeLapseUICommands(recorder: owner)
        let bridge = Bridge(commands: commands)
        bridge.rejectPollAfterJoinedCancellation = true
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        let remote = TimeLapseRecorder(engineClient: client)
        await remote.library.refresh()
        let recording = try #require(remote.library.recordings.first)
        remote.library.export(recording, quality: .original, to: probe.scope.destination)
        await probe.waitForStart()
        remote.library.cancelExport()
        await probe.waitForCancellation()
        #expect(remote.library.exporting && !probe.returned)
        #expect(bridge.operations.contains("recording.ui.exportCancel"))
        probe.release()
        await remote.library.finishExport()
        #expect(probe.returned && probe.exports == 1)
        #expect(bridge.joinedCancellationReplies == 1 && bridge.rejectedPolls == 0)
        #expect(remote.library.message == "Export cancelled.")
        #expect(!remote.library.exporting)
        #expect(bridge.operations.contains("recording.ui.exportPoll"))
        await remote.shutdown()
        client.invalidate()
        await commands.shutdownAndWait()
        await owner.shutdown()
    }

    @available(macOS 15.0, *) @MainActor private final class SavedExportProbe {
        let scope: TimeLapseSavedRecordingScope
        let metadata: Data
        var current = true
        var exports = 0
        var quality: TimeLapseExportQuality?
        var destination: URL?
        var cancelled = false
        var returned = false
        private var callback: CheckedContinuation<Void, Never>?
        private var startWaiter: CheckedContinuation<Void, Never>?
        private var cancelWaiter: CheckedContinuation<Void, Never>?

        init() throws {
            var settings = TimeLapseSettings()
            settings.mode = .standard
            settings.frameRate = 30
            var session = TimeLapseSession(settings: settings, width: 64, height: 64)
            session.segments = [
                .init(
                    file: "video.mp4", kind: "video", frames: 60,
                    startedAt: session.startedAt, duration: 2)
            ]
            session.endedAt = session.startedAt.addingTimeInterval(2)
            metadata = try JSONEncoder().encode(session)
            let id = session.id.uuidString.lowercased()
            let root = "/synthetic/functional-fixture-" + id
            let directory = URL(fileURLWithPath: root + "/inputs/timeLapse/saved-recording")
            scope = try TimeLapseSavedRecordingScope(
                session: id, root: root, phase: "initial",
                metadata: directory.appendingPathComponent("session.json"),
                video: directory.appendingPathComponent("video.mp4"),
                destination: URL(fileURLWithPath: root + "/outputs/timeLapse/initial/Recording.mp4")
            )
        }

        func library() throws -> TimeLapseExportLibrary {
            try TimeLapseExportLibrary(
                scope: scope,
                current: { [self] in
                    guard current else { throw TimeLapseError.invalidSession }
                }, read: { [self] in metadata },
                write: { [self] _, quality, destination in
                    exports += 1
                    self.quality = quality
                    self.destination = destination
                    await withTaskCancellationHandler {
                        await withCheckedContinuation { continuation in
                            callback = continuation
                            startWaiter?.resume()
                            startWaiter = nil
                        }
                    } onCancel: {
                        Task { @MainActor [self] in
                            self.cancelled = true
                            self.cancelWaiter?.resume()
                            self.cancelWaiter = nil
                        }
                    }
                    returned = true
                    try Task.checkCancellation()
                })
        }

        func waitForStart() async {
            if callback != nil { return }
            await withCheckedContinuation { startWaiter = $0 }
        }

        func waitForCancellation() async {
            if cancelled { return }
            await withCheckedContinuation { cancelWaiter = $0 }
        }

        func release() {
            callback?.resume()
            callback = nil
        }
    }

    @available(macOS 15.0, *) @MainActor private final class Bridge: NSObject {
        let commands: TimeLapseUICommands
        let registry = ExtensionCommandRegistry()
        var operations: [String] = []
        var rejectPollAfterJoinedCancellation = false
        var joinedCancellationReplies = 0
        var rejectedPolls = 0
        init(commands: TimeLapseUICommands) { self.commands = commands }
        @objc func invoke(_ data: Data, completion: @escaping (Data) -> Void) {
            guard
                let request = try? ExtensionEngineWire.decode(
                    ExtensionEngineRequest.self, from: data)
            else { completion(Data()); return }
            operations.append(request.operation)
            registry.invoke(
                [
                    "token": request.token.uuidString, "command": request.operation,
                    "payload": request.payload,
                ],
                completion: { bytes, error in
                    completion(
                        (try? ExtensionEngineWire.encode(
                            ExtensionEngineReply(
                                token: request.token, ok: error == nil && bytes != nil,
                                payload: bytes as Data? ?? Data("{}".utf8)))) ?? Data())
                },
                execute: { [self] command, payload in
                    if command == "recording.ui.exportPoll", rejectPollAfterJoinedCancellation,
                        joinedCancellationReplies > 0
                    {
                        rejectedPolls += 1
                        throw ExtensionPeerError.unavailable
                    }
                    let reply = try await commands.execute(command, payload: payload)
                    if command == "recording.ui.exportCancel",
                        let status = try? JSONDecoder().decode(
                            TimeLapseUIExportStatus.self, from: reply), status.complete
                    {
                        joinedCancellationReplies += 1
                    }
                    return reply
                })
        }
        @objc func cancel(_ token: String) { registry.cancel(token) }
    }
}
