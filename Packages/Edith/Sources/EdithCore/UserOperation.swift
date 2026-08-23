import Foundation

public struct UserOperationID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum UserOperationEffect: String, Equatable, Sendable {
    case read
    case write
    case destructive
    case interactive
}

public struct UserOperationDescriptor: Equatable, Sendable {
    public let id: UserOperationID
    public let summary: String
    public let cli: [String]
    public let effect: UserOperationEffect
    public let requiresPreview: Bool

    public init(
        id: UserOperationID, summary: String, cli: [String], effect: UserOperationEffect,
        requiresPreview: Bool = false
    ) {
        self.id = id
        self.summary = summary
        self.cli = cli
        self.effect = effect
        self.requiresPreview = requiresPreview
    }
}
