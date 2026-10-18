import Foundation

public protocol DatabaseBrokerCommandSending: Sendable {
    func send(
        _ request: DatabaseBrokerCommandRequest
    ) async throws -> DatabaseBrokerCommandResponse
}

public enum DatabaseBrokerCommandClientError: Error, Equatable, Sendable {
    case invalidRequest
    case timedOut
    case unavailable
    case unsafePeer
    case outcomeUnknown
}
