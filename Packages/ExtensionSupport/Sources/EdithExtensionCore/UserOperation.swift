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

public struct UserInterfaceActionPlacement: Equatable, Sendable {
    public let surface: String
    public let action: String
    public let exampleArguments: [String]

    public init(surface: String, action: String, exampleArguments: [String] = []) {
        self.surface = surface
        self.action = action
        self.exampleArguments = exampleArguments
    }
}

public enum UserOperationExposure: Equatable, Sendable {
    case userInterface([UserInterfaceActionPlacement])
    case commandLineOnly(reason: String)
}

public struct RegisteredUserOperation: Equatable, Sendable {
    public let descriptor: UserOperationDescriptor
    public let exposure: UserOperationExposure

    public init(descriptor: UserOperationDescriptor, exposure: UserOperationExposure) {
        self.descriptor = descriptor
        self.exposure = exposure
    }
}

public struct RegisteredUserInterfaceAction: Equatable, Sendable {
    public let operation: UserOperationDescriptor
    public let surface: String
    public let action: String
    public let exampleArguments: [String]

    public init(operation: UserOperationDescriptor, placement: UserInterfaceActionPlacement) {
        self.operation = operation
        surface = placement.surface
        action = placement.action
        exampleArguments = placement.exampleArguments
    }

    public var cli: [String] {
        operation.cli + exampleArguments
    }
}

public struct UserInterfacePresentationState: Equatable, Sendable {
    public let surface: String
    public let state: String
    public let reason: String

    public init(surface: String, state: String, reason: String) {
        self.surface = surface
        self.state = state
        self.reason = reason
    }
}
