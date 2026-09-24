import EdithCore

public enum DocsOperation: String, CaseIterable, Equatable, Sendable {
    case list
    case show
    case ask

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .list:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "docs.list"),
                summary: "List the pages of the bundled ed reference.", cli: ["docs", "ls"],
                effect: .read)
        case .show:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "docs.show"),
                summary: "Show one reference page, found by its path or a command it documents.",
                cli: ["docs", "show"], effect: .read)
        case .ask:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "docs.ask"),
                summary: "Rank the commands that handle a plain-language request.",
                cli: ["docs", "ask"], effect: .read)
        }
    }
}
