import EdithExtensionSupport
import Foundation

public enum AudioMixerIPC {
    public static let requestKey = "request"
    public static let requestIDKey = "requestID"
    public static let deadlineKey = "deadline"
    public static let snapshotKey = "snapshot"
    public static let okKey = "ok"
    public static let errorKey = "error"
    public static let appKey = "app"
    public static let volumeKey = "volume"
    public static let targetKey = "target"
}

public struct AudioMixerAppRecord: Codable, Equatable, Sendable {
    public var objectID: UInt32
    public var pid: Int32
    public var bundleID: String
    public var name: String
    public var volume: Double

    public init(
        objectID: UInt32, pid: Int32, bundleID: String, name: String, volume: Double
    ) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.volume = volume
    }

    public var muted: Bool { normalizedVolume == 0 }
    public var normalizedVolume: Double { volume.isFinite ? min(1, max(0, volume)) : 1 }
    public var percent: Int { Int((normalizedVolume * 100).rounded()) }
    public var target: AudioMixerTarget { .init(objectID: objectID, pid: pid, bundleID: bundleID) }
}

public struct AudioMixerTarget: Codable, Equatable, Sendable {
    public let objectID: UInt32
    public let pid: Int32
    public let bundleID: String

    public init(objectID: UInt32, pid: Int32, bundleID: String) {
        self.objectID = objectID; self.pid = pid; self.bundleID = bundleID
    }
    public var valid: Bool {
        objectID > 0 && pid > 0 && !bundleID.isEmpty && bundleID.utf8.count <= 512
    }
    public var id: String { "\(objectID):\(pid):\(bundleID)" }
    public func match(in apps: [AudioMixerAppRecord]) throws -> AudioMixerAppRecord {
        guard valid, let app = apps.first(where: { $0.target == self }) else {
            throw AudioMixerSelectionError.notFound(bundleID)
        }
        return app
    }
}

public struct AudioMixerListSnapshot: Codable, Equatable, Sendable {
    public var apps: [AudioMixerAppRecord]
    public var changed: Bool

    public init(apps: [AudioMixerAppRecord], changed: Bool) {
        self.apps = apps
        self.changed = changed
    }

    public func encoded() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ raw: String?) -> AudioMixerListSnapshot? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AudioMixerListSnapshot.self, from: data)
    }
}

public enum AudioMixerRequest: String, Codable, Sendable {
    case list
    case volume
    case mute
    case unmute
}

public struct AudioMixerRuntimeRequest: Sendable {
    public var request: AudioMixerRequest
    public var app: String
    public var volume: Double
    public var requestID: String
    public var deadline: Date
    public var target: AudioMixerTarget?

    public init(
        request: AudioMixerRequest, app: String = "", volume: Double = 1,
        deadline: Date, requestID: String = UUID().uuidString, target: AudioMixerTarget? = nil
    ) {
        self.request = request
        self.app = app
        self.volume = volume
        self.requestID = requestID
        self.deadline = deadline
        self.target = target
    }

    public var payload: [String: Any] {
        var value: [String: Any] = [
            AudioMixerIPC.requestKey: request.rawValue,
            AudioMixerIPC.appKey: app,
            AudioMixerIPC.volumeKey: volume,
            AudioMixerIPC.requestIDKey: requestID,
            AudioMixerIPC.deadlineKey: deadline.timeIntervalSince1970,
        ]
        if let target, let data = try? JSONEncoder().encode(target) {
            value[AudioMixerIPC.targetKey] = String(decoding: data, as: UTF8.self)
        }
        return value
    }

    public init?(payload: [AnyHashable: Any]) {
        guard let raw = payload[AudioMixerIPC.requestKey] as? String,
            let request = AudioMixerRequest(rawValue: raw),
            let requestID = payload[AudioMixerIPC.requestIDKey] as? String,
            let deadline = payload[AudioMixerIPC.deadlineKey] as? Double, deadline.isFinite,
            !requestID.isEmpty, requestID.utf8.count <= 128
        else { return nil }
        let volume = payload[AudioMixerIPC.volumeKey] as? Double ?? 1
        guard volume.isFinite, (0...1).contains(volume) else { return nil }
        if let raw = payload[AudioMixerIPC.targetKey] {
            guard let text = raw as? String, text.utf8.count <= 2048,
                let decoded = try? JSONDecoder().decode(
                    AudioMixerTarget.self, from: Data(text.utf8)),
                decoded.valid
            else { return nil }
            target = decoded
        }
        self.request = request
        self.app = payload[AudioMixerIPC.appKey] as? String ?? ""
        self.volume = volume
        self.requestID = requestID
        self.deadline = Date(timeIntervalSince1970: deadline)
    }

    public func isLive(at now: Date) -> Bool { deadline >= now }
}

public enum AudioMixerSelectionError: Error, Equatable, LocalizedError {
    case empty
    case notFound(String)
    case ambiguous(String)

    public var errorDescription: String? {
        switch self {
        case .empty: "Name the app, its bundle id, or its process id."
        case let .notFound(query): "No playing app matches \(query)."
        case let .ambiguous(query): "\(query) matches more than one playing app."
        }
    }
}

public enum AudioMixerSelector {
    public static func match(_ query: String, in apps: [AudioMixerAppRecord]) throws
        -> AudioMixerAppRecord
    {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AudioMixerSelectionError.empty }
        let bundles = apps.filter {
            $0.bundleID.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        if bundles.count == 1, let match = bundles.first { return match }
        if bundles.count > 1 { throw AudioMixerSelectionError.ambiguous(trimmed) }
        let names = apps.filter { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        if names.count == 1, let match = names.first { return match }
        if names.count > 1 { throw AudioMixerSelectionError.ambiguous(trimmed) }
        if let pid = Int32(trimmed), let match = apps.first(where: { $0.pid == pid }) {
            return match
        }
        let contained = apps.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
        if contained.count == 1, let match = contained.first { return match }
        if contained.count > 1 { throw AudioMixerSelectionError.ambiguous(trimmed) }
        throw AudioMixerSelectionError.notFound(trimmed)
    }
}

public enum AudioMixerOperation: String, CaseIterable, Equatable, Sendable {
    case list
    case volume
    case mute
    case unmute

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .list: descriptor(["ls"], "List apps that are playing audio.", .read)
        case .volume: descriptor(["volume"], "Set one playing app's volume.", .write)
        case .mute: descriptor(["mute"], "Mute one playing app.", .write)
        case .unmute: descriptor(["unmute"], "Restore one playing app to full volume.", .write)
        }
    }

    private func descriptor(_ path: [String], _ summary: String, _ effect: UserOperationEffect)
        -> UserOperationDescriptor
    {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "audioMixer.\(rawValue)"), summary: summary,
            cli: ["audio"] + path, effect: effect)
    }
}
