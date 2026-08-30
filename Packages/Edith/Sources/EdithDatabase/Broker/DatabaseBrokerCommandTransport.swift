import Foundation

enum DatabaseBrokerCommandServerResponseDisposition: Equatable, Sendable {
    case sent
    case responseSinkDropped
}

struct DatabaseBrokerCommandServerResult: Equatable, Sendable {
    let requestID: UUID
    let disposition: DatabaseBrokerCommandServerResponseDisposition
    let responseBytesWritten: Int
}

struct DatabaseBrokerCommandTransport: Sendable {
    private let transport: DatabaseBrokerHealthTransport

    init() throws {
        transport = try DatabaseBrokerHealthTransport()
    }

    init(dependencies: DatabaseBrokerHealthTransportDependencies) {
        transport = DatabaseBrokerHealthTransport(dependencies: dependencies)
    }

    func request(
        _ command: DatabaseBrokerCommandRequest,
        requestID: UUID = UUID(),
        socketDescriptor: Int32,
        deadlineNanoseconds: UInt64? = nil
    ) throws -> DatabaseBrokerEnvelope<DatabaseBrokerCommandResponse> {
        let request = command.envelope(requestID: requestID, sequence: 0)
        try DatabaseBrokerCommandEnvelopeValidator.validate(request)
        try transport.authenticatePeer(
            socketDescriptor: socketDescriptor,
            absoluteDeadline: deadlineNanoseconds)
        let frame = try DatabaseBrokerCommandFrameCodec.encode(request)
        let writeOutcome = try transport.writeFrame(
            frame,
            socketDescriptor: socketDescriptor,
            sinkClosureIsResult: false,
            absoluteDeadline: deadlineNanoseconds)
        let response: DatabaseBrokerEnvelope<DatabaseBrokerCommandResponse> =
            try transport.readFrame(
                socketDescriptor: socketDescriptor,
                stream: .responses,
                bytesWritten: writeOutcome.bytesWritten,
                absoluteDeadline: deadlineNanoseconds)
        try DatabaseBrokerCommandEnvelopeValidator.validate(
            response,
            matching: request)
        return response
    }

    func receiveRequest(
        socketDescriptor: Int32,
        deadlineNanoseconds: UInt64? = nil
    ) throws -> DatabaseBrokerEnvelope<DatabaseBrokerCommandRequest> {
        try transport.authenticatePeer(
            socketDescriptor: socketDescriptor,
            absoluteDeadline: deadlineNanoseconds)
        let request: DatabaseBrokerEnvelope<DatabaseBrokerCommandRequest> =
            try transport.readFrame(
                socketDescriptor: socketDescriptor,
                stream: .requests,
                bytesWritten: 0,
                absoluteDeadline: deadlineNanoseconds)
        try DatabaseBrokerCommandEnvelopeValidator.validate(request)
        return request
    }

    func sendResponse(
        _ response: DatabaseBrokerEnvelope<DatabaseBrokerCommandResponse>,
        matching request: DatabaseBrokerEnvelope<DatabaseBrokerCommandRequest>,
        socketDescriptor: Int32,
        deadlineNanoseconds: UInt64? = nil
    ) throws -> DatabaseBrokerCommandServerResult {
        let frame = try DatabaseBrokerCommandFrameCodec.encode(
            response,
            matching: request)
        let writeOutcome = try transport.writeFrame(
            frame,
            socketDescriptor: socketDescriptor,
            sinkClosureIsResult: true,
            absoluteDeadline: deadlineNanoseconds)
        return DatabaseBrokerCommandServerResult(
            requestID: request.requestID,
            disposition: writeOutcome.sinkClosed ? .responseSinkDropped : .sent,
            responseBytesWritten: writeOutcome.bytesWritten)
    }
}

enum DatabaseBrokerRuntimeRequestPayload: Codable, Sendable {
    case health(DatabaseBrokerHealthRequest)
    case command(DatabaseBrokerCommandRequest)

    private enum CodingKeys: String, CodingKey {
        case type
        case command
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.type) {
            self = .health(try DatabaseBrokerHealthRequest(from: decoder))
            return
        }
        if container.contains(.command) {
            self = .command(try DatabaseBrokerCommandRequest(from: decoder))
            return
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown broker request payload"))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .health(let request):
            try request.encode(to: encoder)
        case .command(let request):
            try request.encode(to: encoder)
        }
    }
}

struct DatabaseBrokerRuntimeRequestTransport: Sendable {
    private let healthTransport: DatabaseBrokerHealthTransport
    private let commandTransport: DatabaseBrokerCommandTransport

    init() throws {
        let healthTransport = try DatabaseBrokerHealthTransport()
        self.healthTransport = healthTransport
        commandTransport = DatabaseBrokerCommandTransport(
            dependencies: healthTransport.dependencies)
    }

    init(dependencies: DatabaseBrokerHealthTransportDependencies) {
        healthTransport = DatabaseBrokerHealthTransport(dependencies: dependencies)
        commandTransport = DatabaseBrokerCommandTransport(dependencies: dependencies)
    }

    func receiveRequest(
        socketDescriptor: Int32,
        deadlineNanoseconds: UInt64? = nil
    ) throws -> DatabaseBrokerEnvelope<DatabaseBrokerRuntimeRequestPayload> {
        try healthTransport.authenticatePeer(
            socketDescriptor: socketDescriptor,
            absoluteDeadline: deadlineNanoseconds)
        let request: DatabaseBrokerEnvelope<DatabaseBrokerRuntimeRequestPayload> =
            try healthTransport.readFrame(
                socketDescriptor: socketDescriptor,
                stream: .requests,
                bytesWritten: 0,
                absoluteDeadline: deadlineNanoseconds)
        switch request.payload {
        case .health(let payload):
            try DatabaseBrokerHealthRequestValidator.validate(
                DatabaseBrokerEnvelope(
                    requestID: request.requestID,
                    operationID: request.operationID,
                    sequence: request.sequence,
                    kind: request.kind,
                    payload: payload))
        case .command(let payload):
            try DatabaseBrokerCommandEnvelopeValidator.validate(
                DatabaseBrokerEnvelope(
                    requestID: request.requestID,
                    operationID: request.operationID,
                    sequence: request.sequence,
                    kind: request.kind,
                    payload: payload))
        }
        return request
    }

    func sendHealthResponse(
        _ response: DatabaseBrokerHealthResponse,
        matching request: DatabaseBrokerEnvelope<DatabaseBrokerRuntimeRequestPayload>,
        socketDescriptor: Int32,
        deadlineNanoseconds: UInt64? = nil
    ) throws -> DatabaseBrokerHealthServerResult {
        guard case .health = request.payload else {
            throw DatabaseBrokerCommandContractError.missingRequest(request.requestID)
        }
        let envelope = DatabaseBrokerEnvelope(
            requestID: request.requestID,
            sequence: 0,
            kind: DatabaseBrokerEnvelopeKind.response,
            payload: response)
        let frame = try DatabaseBrokerFrameCodec.encode(envelope, stream: .responses)
        let writeOutcome = try healthTransport.writeFrame(
            frame,
            socketDescriptor: socketDescriptor,
            sinkClosureIsResult: true,
            absoluteDeadline: deadlineNanoseconds)
        return DatabaseBrokerHealthServerResult(
            requestID: request.requestID,
            disposition: writeOutcome.sinkClosed ? .responseSinkDropped : .sent,
            responseBytesWritten: writeOutcome.bytesWritten)
    }

    func sendCommandResponse(
        _ response: DatabaseBrokerEnvelope<DatabaseBrokerCommandResponse>,
        matching request: DatabaseBrokerEnvelope<DatabaseBrokerRuntimeRequestPayload>,
        socketDescriptor: Int32,
        deadlineNanoseconds: UInt64? = nil
    ) throws -> DatabaseBrokerCommandServerResult {
        guard case .command(let payload) = request.payload else {
            throw DatabaseBrokerCommandContractError.missingRequest(request.requestID)
        }
        let commandRequest = DatabaseBrokerEnvelope(
            requestID: request.requestID,
            operationID: request.operationID,
            sequence: request.sequence,
            kind: request.kind,
            payload: payload)
        return try commandTransport.sendResponse(
            response,
            matching: commandRequest,
            socketDescriptor: socketDescriptor,
            deadlineNanoseconds: deadlineNanoseconds)
    }
}
