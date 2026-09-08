import EdithCore

public enum CommandBarOperation: String, CaseIterable, Sendable {
    case calculate
    case convert

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .calculate:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "commandBar.calculate"),
                summary: "Evaluate a local arithmetic expression.",
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
        case .calculate:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Command Bar", action: "Evaluate arithmetic inline",
                    exampleArguments: ["2 + 3 * 4"])
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
