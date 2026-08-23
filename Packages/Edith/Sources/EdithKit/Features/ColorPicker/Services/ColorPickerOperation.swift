import AppKit
import EdithCore
import Foundation

public enum ColorPickerOperation: String, CaseIterable, Sendable {
    case pick

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "color.pick"),
            summary: "Open the system color sampler.", cli: ["color", rawValue],
            effect: .interactive)
    }
}

public enum ColorPickerOperationExecution {
    public static func request(
        _ operation: ColorPickerOperation,
        post: (Notification.Name) -> Void = { IPC.post($0) }
    ) -> UserOperationDescriptor {
        post(operation.notification)
        return operation.descriptor
    }

    @MainActor
    public static func perform(
        _ operation: ColorPickerOperation,
        show: (@escaping @Sendable (NSColor?) -> Void) -> Void = {
            NSColorSampler().show(selectionHandler: $0)
        },
        selection: @escaping @Sendable (NSColor?) -> Void
    ) {
        switch operation {
        case .pick: show(selection)
        }
    }
}

private extension ColorPickerOperation {
    var notification: Notification.Name {
        switch self {
        case .pick: IPC.Name.requestColorPick
        }
    }
}
