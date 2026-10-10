import EdithExtensionSupport
import Foundation

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

}

public enum StudioRecordRequest: String, Codable, Sendable {
    case sources
    case start
    case stop
    case status
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
