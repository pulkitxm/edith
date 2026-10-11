import Foundation

@MainActor
public final class HostPresentationDelivery: Identifiable, Equatable {
    public nonisolated let id = UUID()
    public let extensionID: String
    public let version: String
    private var receipt: Result<@MainActor () throws -> Void, any Error>?

    public init(extensionID: String, version: String) {
        self.extensionID = extensionID; self.version = version
    }

    public nonisolated static func == (lhs: HostPresentationDelivery, rhs: HostPresentationDelivery)
        -> Bool
    {
        lhs.id == rhs.id
    }

    public var pending: Bool { receipt == nil }

    public func receive(
        presentationID: UUID, extensionID: String, version: String,
        validate: @escaping @MainActor () throws -> Void
    ) throws {
        try Task.checkCancellation()
        guard receipt == nil, presentationID == id, extensionID == self.extensionID,
            version == self.version
        else { throw HostPresentationDeliveryError.rejected }
        try validate()
        receipt = .success(validate)
    }

    public func reject(_ error: any Error = HostPresentationDeliveryError.rejected) {
        receipt = .failure(error)
    }

    public func validate() throws {
        try Task.checkCancellation()
        guard let receipt else { throw HostPresentationDeliveryError.unavailable }
        try receipt.get()()
    }

    public func wait(timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        do {
            while receipt == nil {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else {
                    throw HostPresentationDeliveryError.timedOut
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            try validate()
        } catch {
            reject(error)
            throw error
        }
    }
}

public enum HostPresentationDeliveryError: Error, Equatable {
    case unavailable
    case rejected
    case timedOut
}
