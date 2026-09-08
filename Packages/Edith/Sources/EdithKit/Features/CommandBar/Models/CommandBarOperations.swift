import EdithCore

public enum CommandBarOperation: String, CaseIterable, Sendable {
    case calculate
    case convert
    case transform
    case copy

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .copy:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "commandBar.copy"),
                summary: "Copy a Command Bar text result to the clipboard.",
                cli: ["command-bar", rawValue], effect: .write)
        case .calculate:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "commandBar.calculate"),
                summary: "Evaluate a local arithmetic expression.",
                cli: ["command-bar", rawValue], effect: .read)
        case .transform:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "commandBar.transform"),
                summary: "Transform text with the Command Bar utilities.",
                cli: ["command-bar", rawValue], effect: .read)
        case .convert:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "commandBar.convert"),
                summary: "Convert a value between compatible units.",
                cli: ["command-bar", rawValue], effect: .read)
        }
    }

    public var interfaceExposure: UserOperationExposure {
        switch self {
        case .copy:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Command Bar", action: "Copy an emoji result", exampleArguments: ["🚀"])
            ])
        case .calculate:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Command Bar", action: "Evaluate arithmetic inline",
                    exampleArguments: ["2 + 3 * 4"])
            ])
        case .transform:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Command Bar", action: "Transform selected text",
                    exampleArguments: ["uppercase", "hello world"])
            ])
        case .convert:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Command Bar", action: "Convert compatible units inline",
                    exampleArguments: ["5", "km", "mi"])
            ])
        }
    }
}
