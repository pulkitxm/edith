import EdithCore
import Foundation

public enum CaptureToolOperation: String, CaseIterable, Sendable {
    case read
    case screenshot

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .read:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "capture.read"),
                summary: "Select part of the screen and recognize text or codes.",
                cli: ["capture", rawValue], effect: .interactive)
        case .screenshot:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "capture.screenshot"),
                summary: "Select part of the screen for a lightweight preview.",
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
        case .screenshot: IPC.Name.requestScreenshot
        }
    }
}
