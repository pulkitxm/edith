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
