import EdithCore
import Foundation

public enum ScreenRecordingOperation: String, CaseIterable, Sendable {
    case area
    case window
    case display
    case pause
    case resume
    case stop
    case cancel
    case status
    case library

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "capture.record.\(rawValue)"),
            summary: summary, cli: ["capture", "record", rawValue],
            effect: effect)
    }

    public static func request(
        _ operation: ScreenRecordingOperation,
        post: (Notification.Name) -> Void = { IPC.post($0) }
    ) -> UserOperationDescriptor {
        if let notification = operation.notification { post(notification) }
        return operation.descriptor
    }

    private var summary: String {
        switch self {
        case .area: "Select an area and begin recording it."
        case .window: "Choose a window and begin recording it."
        case .display: "Choose a display and begin recording it."
        case .pause: "Pause the active recording."
        case .resume: "Resume the paused recording."
        case .stop: "Stop the active recording and open its editor."
        case .cancel: "Cancel and discard the active recording."
        case .status: "Read the current recording status."
        case .library: "Open recent and recovered recordings."
        }
    }

    private var effect: UserOperationEffect {
        switch self {
        case .status: .read
        case .cancel: .destructive
        default: .interactive
        }
    }

    private var notification: Notification.Name? {
        switch self {
        case .area: IPC.Name.requestRecordingArea
        case .window: IPC.Name.requestRecordingWindow
        case .display: IPC.Name.requestRecordingDisplay
        case .pause: IPC.Name.requestRecordingPause
        case .resume: IPC.Name.requestRecordingResume
        case .stop: IPC.Name.requestRecordingStop
        case .cancel: IPC.Name.requestRecordingCancel
        case .library: IPC.Name.requestRecordingLibrary
        case .status: nil
        }
    }
}

public enum ScreenRecordingStatusStore {
    public static func load(
        defaults: UserDefaults = SharedDefaults.store
    ) -> ScreenRecordingStatus {
        guard let data = defaults.data(forKey: AppStorageKeys.Capture.recordingStatus),
            let status = try? JSONDecoder().decode(ScreenRecordingStatus.self, from: data)
        else { return ScreenRecordingStatus() }
        return status
    }
}
