import AppKit
import EdithCore
import Foundation

public enum SurfaceRecorderOperation: String, Codable, Sendable {
    case status, stop
}

public struct SurfaceRecorderRequest: Codable, Sendable {
    public let id: UUID
    public let operation: SurfaceRecorderOperation
    public let sessionID: UUID?
    public let deadline: Date
    public init(_ operation: SurfaceRecorderOperation, sessionID: UUID? = nil, now: Date = Date()) {
        id = UUID(); self.operation = operation; self.sessionID = sessionID
        deadline = now.addingTimeInterval(8)
    }
    public func isLive(at now: Date) -> Bool {
        deadline.timeIntervalSince1970.isFinite && deadline >= now
            && deadline.timeIntervalSince(now) <= 9
            && (operation != .stop || sessionID != nil)
    }
}

public struct SurfaceRecorderSnapshot: Codable, Equatable, Sendable {
    public var sessionID: UUID?
    public var recording = false
    public var busy = false
    public var startedAt: Date?
    public var frames: Int64 = 0
    public var bytes: Int64 = 0
    public var playbackSeconds: Double = 0
    public var mode = ScreenRecordingMode.standard
    public var frameRate: Int32 = 30
    public var interval: Double = 5
    public var sourceMode = "displays"
    public var sources = 0
    public var systemAudio = false
    public var microphone = false
    public var error: String?
    public init() {}
    public func permitsStop(_ request: SurfaceRecorderRequest, now: Date = Date()) -> Bool {
        request.operation == .stop && request.isLive(at: now) && recording && !busy
            && sessionID != nil && sessionID == request.sessionID
    }
}

public enum SurfaceMediaRuntimeError: LocalizedError {
    case unavailable(String), invalidReply, invalidVolume
    public var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        case .invalidReply: "The media app returned an unreadable reply. Refresh this widget."
        case .invalidVolume: "Choose an available audio app and a volume from 0 to 100 percent."
        }
    }
}

public enum SurfaceMediaClient {
    public static func audio(
        _ operation: AudioMixerRequest = .list, target: AudioMixerTarget? = nil, volume: Double = 1
    ) async throws -> AudioMixerListSnapshot {
        guard SurfaceWidget.ability("audioMixer").available(in: SharedDefaults.store) else {
            throw SurfaceMediaRuntimeError.unavailable("Enable Audio Mixer in Extensions.")
        }
        guard volume.isFinite, (0...1).contains(volume),
            operation == .list || target?.valid == true
        else { throw SurfaceMediaRuntimeError.invalidVolume }
        guard running(MainApp.statusBarBundleIdentifier) else {
            throw SurfaceMediaRuntimeError.unavailable(
                "Open Edith's menu bar app to load audio apps.")
        }
        let request = AudioMixerRuntimeRequest(
            request: operation, volume: volume, deadline: Date().addingTimeInterval(8),
            target: target)
        guard
            let reply = await IPCReplyAwaiter.awaitReply(
                IPC.Name.audioMixerActionResult, timeout: 8,
                matching: { $0[AudioMixerIPC.requestIDKey] as? String == request.requestID },
                trigger: { IPC.post(IPC.Name.requestAudioMixerAction, userInfo: request.payload) })
        else {
            try Task.checkCancellation()
            throw SurfaceMediaRuntimeError.unavailable(
                "The audio mixer did not answer. Refresh this widget.")
        }
        guard reply[AudioMixerIPC.okKey] as? Bool == true else {
            throw SurfaceMediaRuntimeError.unavailable(
                reply[AudioMixerIPC.errorKey] as? String ?? "The audio adjustment failed.")
        }
        guard let text = reply[AudioMixerIPC.snapshotKey] as? String, text.utf8.count <= 1_048_576,
            let snapshot = AudioMixerListSnapshot.decode(text), snapshot.apps.count <= 512
        else { throw SurfaceMediaRuntimeError.invalidReply }
        return snapshot
    }
    public static func recorder(
        _ operation: SurfaceRecorderOperation = .status, sessionID: UUID? = nil
    ) async throws -> SurfaceRecorderSnapshot? {
        guard SurfaceWidget.ability("timeLapse").available(in: SharedDefaults.store) else {
            throw SurfaceMediaRuntimeError.unavailable("Enable Screen Recorder in Extensions.")
        }
        guard running(MainApp.bundleIdentifier) else {
            if operation == .status { return nil }
            throw SurfaceMediaRuntimeError.unavailable(
                "Open Screen Recorder to manage the active recording.")
        }
        let request = SurfaceRecorderRequest(operation, sessionID: sessionID)
        guard request.isLive(at: Date()) else { throw SurfaceMediaRuntimeError.invalidReply }
        let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        guard
            let reply = await IPCReplyAwaiter.awaitReply(
                IPC.Name.recorderSurfaceResult, timeout: 8,
                matching: { $0["requestID"] as? String == request.id.uuidString },
                trigger: {
                    IPC.post(IPC.Name.requestRecorderSurface, userInfo: ["request": encoded])
                })
        else {
            try Task.checkCancellation()
            throw SurfaceMediaRuntimeError.unavailable(
                "Screen Recorder did not answer. Open it to review recording status.")
        }
        guard reply["ok"] as? Bool == true else {
            throw SurfaceMediaRuntimeError.unavailable(
                reply["error"] as? String ?? "The recording changed. Refresh this widget.")
        }
        guard let text = reply["snapshot"] as? String, text.utf8.count <= 32_768,
            let snapshot = try? JSONDecoder().decode(
                SurfaceRecorderSnapshot.self, from: Data(text.utf8))
        else { throw SurfaceMediaRuntimeError.invalidReply }
        return snapshot
    }
    private static func running(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}
