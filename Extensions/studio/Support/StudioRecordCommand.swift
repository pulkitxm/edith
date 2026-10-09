import EdithExtensionSupport
import Foundation

public enum StudioRecordIPC {
    public static let requestKey = "request"
    public static let requestIDKey = "requestID"
    public static let deadlineKey = "deadline"
    public static let snapshotKey = "snapshot"
    public static let okKey = "ok"
    public static let errorKey = "error"
    public static let sourceKey = "source"
    public static let systemAudioKey = "systemAudio"
    public static let microphoneKey = "microphone"
    public static let cursorKey = "cursor"
}

public struct StudioRecordSource: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var title: String

    public init(id: String, kind: String, title: String) {
        self.id = id
        self.kind = kind
        self.title = title
    }
}

public struct StudioRecordSnapshot: Codable, Equatable, Sendable {
    public var sources: [StudioRecordSource]
    public var recording: Bool
    public var source: String
    public var systemAudio: Bool
    public var microphone: Bool
    public var showCursor: Bool
    public var output: String?
    public var changed: Bool

    public init(
        sources: [StudioRecordSource], recording: Bool, source: String, systemAudio: Bool,
        microphone: Bool, showCursor: Bool, output: String?, changed: Bool
    ) {
        self.sources = sources
        self.recording = recording
        self.source = source
        self.systemAudio = systemAudio
        self.microphone = microphone
        self.showCursor = showCursor
        self.output = output
        self.changed = changed
    }

    public func encoded() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ raw: String?) -> StudioRecordSnapshot? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StudioRecordSnapshot.self, from: data)
    }
}

public enum StudioRecordRequest: String, Codable, Sendable {
    case sources
    case start
    case stop
    case status
}

public struct StudioRecordRuntimeRequest: Sendable {
    public var request: StudioRecordRequest
    public var source: String
    public var systemAudio: Bool
    public var microphone: Bool
    public var showCursor: Bool
    public var requestID: String
    public var deadline: Date

    public init(
        request: StudioRecordRequest, source: String = "", systemAudio: Bool = true,
        microphone: Bool = false, showCursor: Bool = true, deadline: Date,
        requestID: String = UUID().uuidString
    ) {
        self.request = request
        self.source = source
        self.systemAudio = systemAudio
        self.microphone = microphone
        self.showCursor = showCursor
        self.requestID = requestID
        self.deadline = deadline
    }

    public var payload: [String: Any] {
        [
            StudioRecordIPC.requestKey: request.rawValue,
            StudioRecordIPC.sourceKey: source,
            StudioRecordIPC.systemAudioKey: systemAudio,
            StudioRecordIPC.microphoneKey: microphone,
            StudioRecordIPC.cursorKey: showCursor,
            StudioRecordIPC.requestIDKey: requestID,
            StudioRecordIPC.deadlineKey: deadline.timeIntervalSince1970,
        ]
    }

    public init?(payload: [AnyHashable: Any]) {
        guard let raw = payload[StudioRecordIPC.requestKey] as? String,
            let request = StudioRecordRequest(rawValue: raw),
            let requestID = payload[StudioRecordIPC.requestIDKey] as? String,
            let deadline = payload[StudioRecordIPC.deadlineKey] as? Double
        else { return nil }
        self.request = request
        self.source = payload[StudioRecordIPC.sourceKey] as? String ?? ""
        self.systemAudio = payload[StudioRecordIPC.systemAudioKey] as? Bool ?? true
        self.microphone = payload[StudioRecordIPC.microphoneKey] as? Bool ?? false
        self.showCursor = payload[StudioRecordIPC.cursorKey] as? Bool ?? true
        self.requestID = requestID
        self.deadline = Date(timeIntervalSince1970: deadline)
    }

    public func isLive(at now: Date) -> Bool { deadline >= now }
}

public enum StudioRecordOperation: String, CaseIterable, Sendable {
    case sources
    case start
    case stop
    case status

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .sources:
            descriptor(
                ["record", "sources"], "List displays and windows that can be recorded.", .read)
        case .start: descriptor(["record", "start"], "Start a screen recording.", .write)
        case .stop: descriptor(["record", "stop"], "Stop the screen recording.", .write)
        case .status:
            descriptor(
                ["record", "status"], "Read whether a screen recording is in progress.", .read)
        }
    }

    public var interfaceExposure: UserOperationExposure {
        switch self {
        case .sources:
            userInterface("Video recorder", "list recording sources")
        case .start:
            userInterface("Video recorder", "start recording")
        case .stop:
            userInterface("Video recorder", "stop recording")
        case .status:
            userInterface("Video recorder", "read the recording")
        }
    }

    private func descriptor(_ path: [String], _ summary: String, _ effect: UserOperationEffect)
        -> UserOperationDescriptor
    {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "studio.record.\(rawValue)"), summary: summary,
            cli: ["studio"] + path, effect: effect)
    }
}

public enum StudioWorkflowOperation: String, CaseIterable, Sendable {
    case ls
    case save
    case run
    case rm

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .ls: descriptor(["workflow", "ls"], "List saved Studio workflows.", .read)
        case .save: descriptor(["workflow", "save"], "Save a chain of Studio tools.", .write)
        case .run: descriptor(["workflow", "run"], "Run a saved Studio workflow on files.", .write)
        case .rm: descriptor(["workflow", "rm"], "Delete a saved Studio workflow.", .write)
        }
    }

    public var interfaceExposure: UserOperationExposure {
        switch self {
        case .ls:
            userInterface("Studio workflows", "list saved workflows")
        case .save:
            userInterface(
                "Studio workflows", "save a workflow", ["Web photos", "--step", "image.compress"])
        case .run:
            userInterface("Studio workflows", "run a workflow", ["Web photos", "photo.png"])
        case .rm:
            userInterface("Studio workflows", "delete a workflow", ["Web photos", "--yes"])
        }
    }

    private func descriptor(_ path: [String], _ summary: String, _ effect: UserOperationEffect)
        -> UserOperationDescriptor
    {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "studio.workflow.\(rawValue)"), summary: summary,
            cli: ["studio"] + path, effect: effect)
    }
}

private func userInterface(_ surface: String, _ action: String, _ exampleArguments: [String] = [])
    -> UserOperationExposure
{
    .userInterface([
        UserInterfaceActionPlacement(
            surface: surface, action: action, exampleArguments: exampleArguments)
    ])
}
