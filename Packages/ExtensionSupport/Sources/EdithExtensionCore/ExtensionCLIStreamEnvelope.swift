import Foundation

public struct ExtensionCLIStreamStart: Codable, Sendable {
    public let owner: String
    public let session: UUID
    public let request: ExtensionCLIRequest
    public let deadline: Double

    public init(
        owner: String, session: UUID, request: ExtensionCLIRequest, deadline: Double = 1_800
    ) {
        self.owner = owner
        self.session = session
        self.request = request
        self.deadline = deadline
    }

    public func validate() throws {
        try request.validate()
        guard !owner.isEmpty, owner.utf8.count <= 128, !owner.utf8.contains(0),
            deadline.isFinite, deadline > 0, deadline <= 21_600
        else { throw ExtensionPeerError.invalidRequest }
    }
}

public struct ExtensionCLIStreamHandle: Codable, Equatable, Sendable {
    public let owner: String
    public let session: UUID
    public let token: UUID

    public init(owner: String, session: UUID, token: UUID) {
        self.owner = owner
        self.session = session
        self.token = token
    }
}

public struct ExtensionCLIStreamRead: Codable, Sendable {
    public let handle: ExtensionCLIStreamHandle
    public let sequence: UInt64

    public init(handle: ExtensionCLIStreamHandle, sequence: UInt64) {
        self.handle = handle
        self.sequence = sequence
    }
}

public struct ExtensionCLIStreamChunk: Codable, Equatable, Sendable {
    public enum Channel: String, Codable, Sendable { case stdout, stderr }
    public let sequence: UInt64
    public let channel: Channel
    public let data: Data

    public init(sequence: UInt64, channel: Channel, data: Data) {
        self.sequence = sequence
        self.channel = channel
        self.data = data
    }
}

public struct ExtensionCLIStreamFrame: Codable, Sendable {
    public enum State: String, Codable, Sendable {
        case running, completed, cancelled, timedOut, overflow, failed
    }
    public static let maximumFrameBytes = 256 * 1_024
    public let handle: ExtensionCLIStreamHandle
    public let sequence: UInt64
    public let nextSequence: UInt64
    public let chunks: [ExtensionCLIStreamChunk]
    public let state: State
    public let exitCode: Int32?

    public init(
        handle: ExtensionCLIStreamHandle, sequence: UInt64, nextSequence: UInt64,
        chunks: [ExtensionCLIStreamChunk], state: State, exitCode: Int32?
    ) {
        self.handle = handle
        self.sequence = sequence
        self.nextSequence = nextSequence
        self.chunks = chunks
        self.state = state
        self.exitCode = exitCode
    }

    public func validate() throws {
        guard chunks.count <= 64,
            chunks.reduce(0, { $0 + $1.data.count }) <= Self.maximumFrameBytes,
            nextSequence >= sequence, nextSequence - sequence == UInt64(chunks.count),
            chunks.enumerated().allSatisfy({ index, chunk in
                chunk.sequence == sequence + UInt64(index) && !chunk.data.isEmpty
                    && chunk.data.count <= 64 * 1_024
            }), exitCode.map({ (0...255).contains($0) }) ?? true,
            (state == .completed) == (exitCode != nil)
        else { throw ExtensionPeerError.invalidRequest }
    }
}
