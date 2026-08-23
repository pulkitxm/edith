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

public enum ColorSwatchOperation: String, CaseIterable, Sendable {
    case copy

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "color.copy"),
            summary: "Copy a picked colour to the pasteboard.", cli: ["color", rawValue],
            effect: .write)
    }
}

public struct ColorSwatchOperationResult: Equatable, Sendable {
    public var operation: ColorSwatchOperation
    public var swatchID: UUID
    public var format: ColorCopyFormat
    public var value: String

    public init(
        operation: ColorSwatchOperation, swatchID: UUID, format: ColorCopyFormat, value: String
    ) {
        self.operation = operation
        self.swatchID = swatchID
        self.format = format
        self.value = value
    }
}

public enum ColorSwatchOperationError: LocalizedError, Equatable {
    case pasteboardRejected

    public var errorDescription: String? {
        "The pasteboard refused the colour value."
    }
}

public enum ColorSwatchOperationExecution {
    @discardableResult
    public static func perform(
        _ operation: ColorSwatchOperation, swatch: ColorSwatch, format: ColorCopyFormat,
        write: (String) -> Bool
    ) throws -> ColorSwatchOperationResult {
        let value = swatch.string(for: format)
        guard write(value) else { throw ColorSwatchOperationError.pasteboardRejected }
        return ColorSwatchOperationResult(
            operation: operation, swatchID: swatch.id, format: format, value: value)
    }
}

private extension ColorPickerOperation {
    var notification: Notification.Name {
        switch self {
        case .pick: IPC.Name.requestColorPick
        }
    }
}
