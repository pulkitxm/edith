import EdithCore
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

    public var muted: Bool { volume == 0 }
    public var percent: Int { Int((volume * 100).rounded()) }
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

    public init(
        request: AudioMixerRequest, app: String = "", volume: Double = 1,
        deadline: Date, requestID: String = UUID().uuidString
    ) {
        self.request = request
        self.app = app
        self.volume = volume
        self.requestID = requestID
        self.deadline = deadline
    }

    public var payload: [String: Any] {
        [
            AudioMixerIPC.requestKey: request.rawValue,
            AudioMixerIPC.appKey: app,
            AudioMixerIPC.volumeKey: volume,
            AudioMixerIPC.requestIDKey: requestID,
            AudioMixerIPC.deadlineKey: deadline.timeIntervalSince1970,
        ]
    }

    public init?(payload: [AnyHashable: Any]) {
        guard let raw = payload[AudioMixerIPC.requestKey] as? String,
            let request = AudioMixerRequest(rawValue: raw),
            let requestID = payload[AudioMixerIPC.requestIDKey] as? String,
            let deadline = payload[AudioMixerIPC.deadlineKey] as? Double
        else { return nil }
        self.request = request
        self.app = payload[AudioMixerIPC.appKey] as? String ?? ""
        self.volume = payload[AudioMixerIPC.volumeKey] as? Double ?? 1
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
