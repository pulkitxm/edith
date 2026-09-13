import EdithCore
import Foundation

public enum CaptureToolOperation: String, CaseIterable, Sendable {
    case read
    case area
    case window
    case screen
    case library

    public var captureMode: CaptureMode? {
        switch self {
        case .read, .area: .area
        case .window: .window
        case .screen: .screen
        case .library: nil
        }
    }

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .read:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "capture.read"),
                summary: "Select part of the screen and recognize text or codes.",
                cli: ["capture", rawValue], effect: .interactive)
        case .area:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "capture.area"),
                summary: "Capture an area and open its quick preview.",
                cli: ["capture", rawValue], effect: .interactive)
        case .window:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "capture.window"),
                summary: "Capture a window and open its quick preview.",
                cli: ["capture", rawValue], effect: .interactive)
        case .screen:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "capture.screen"),
                summary: "Capture the full main display and open its quick preview.",
                cli: ["capture", rawValue], effect: .interactive)
        case .library:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "capture.library"),
                summary: "Open the recent captures library.",
                cli: ["capture", rawValue], effect: .interactive)
        }
    }
}

public enum CaptureToolOperationExecution {
    public static func request(
        _ operation: CaptureToolOperation,
        post: (Notification.Name) -> Void = { IPC.post($0) }
    ) -> UserOperationDescriptor {
        post(operation.notification)
        return operation.descriptor
    }
}

private extension CaptureToolOperation {
    var notification: Notification.Name {
        switch self {
        case .read: IPC.Name.requestScreenRead
        case .area: IPC.Name.requestCaptureArea
        case .window: IPC.Name.requestCaptureWindow
        case .screen: IPC.Name.requestCaptureScreen
        case .library: IPC.Name.requestCaptureLibrary
        }
    }
}
