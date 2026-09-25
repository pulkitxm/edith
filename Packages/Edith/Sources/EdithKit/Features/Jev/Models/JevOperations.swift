import EdithCore

public enum JevOperation: String, CaseIterable, Equatable, Sendable {
    case status
    case keySet
    case keyClear
    case ask

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .status:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "jev.status"),
                summary: "Show whether a Jev key is set and whether it can make decisions.",
                cli: ["jev", "status"], effect: .read)
        case .keySet:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "jev.key.set"),
                summary: "Store the TypeSafe API key that turns Jev features on.",
                cli: ["jev", "key", "set"], effect: .write)
        case .keyClear:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "jev.key.clear"),
                summary: "Remove the TypeSafe API key, which turns every Jev feature off.",
                cli: ["jev", "key", "clear"], effect: .destructive, requiresPreview: true)
        case .ask:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "jev.ask"),
                summary: "Send a raw Jev request with a state and typed questions.",
                cli: ["jev", "ask"], effect: .read)
        }
    }
}
