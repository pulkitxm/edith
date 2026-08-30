import Darwin
import Dispatch
import Foundation
import Testing

@testable import EdithDatabase

@Test func databaseBrokerCommandTransportRoundTripsOneBoundedCommand() async throws {
    let sockets = try databaseBrokerCommandTransportSocketPair()
    defer {
        Darwin.close(sockets.client)
        Darwin.close(sockets.server)
    }
    let transport = DatabaseBrokerCommandTransport(
        dependencies: databaseBrokerCommandTransportDependencies())
    let requestID = UUID(uuidString: "482C3E8D-949F-4A2F-BC29-58063B8F9B21")!
    let command = DatabaseBrokerCommandRequest.connectionList(
        DatabaseConnectionListRequest(
            search: DatabaseConnectionSearch(limit: 5)))
    let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
    let server = Task.detached {
        let request = try transport.receiveRequest(
            socketDescriptor: sockets.server,
            deadlineNanoseconds: deadline)
        let result = DatabaseCommandResult.success(
            DatabaseConnectionListResult(connections: []),
            metadata: DatabaseResultMetadata(
                completeness: DatabaseResultCompleteness(state: .complete),
                count: DatabaseCountMetadata(value: 0, accuracy: .exact)))
        let payload = try request.payload.response(result)
        let response = try payload.envelope(matching: request, sequence: 0)
        return try transport.sendResponse(
            response,
            matching: request,
            socketDescriptor: sockets.server,
            deadlineNanoseconds: deadline)
    }
    let response = try transport.request(
        command,
        requestID: requestID,
        socketDescriptor: sockets.client,
        deadlineNanoseconds: deadline)
    let serverResult = try await server.value
    #expect(response.requestID == requestID)
    #expect(response.payload.connectionListResult?.payload?.connections == [])
    #expect(response.payload.connectionListResult?.metadata.count?.value == 0)
    #expect(serverResult.requestID == requestID)
    #expect(serverResult.disposition == .sent)
    #expect(serverResult.responseBytesWritten > 0)
}

@Test func databaseBrokerCommandTransportRejectsExpiredDeadlineBeforeAuthentication() throws {
    let dependencies = databaseBrokerCommandTransportDependencies(
        monotonicNanoseconds: { 100 })
    let transport = DatabaseBrokerCommandTransport(dependencies: dependencies)
    let command = DatabaseBrokerCommandRequest.connectionList(
        DatabaseConnectionListRequest())
    #expect(throws: DatabaseBrokerHealthTransportError.self) {
        _ = try transport.request(
            command,
            socketDescriptor: -1,
            deadlineNanoseconds: 100)
    }
}

private func databaseBrokerCommandTransportSocketPair() throws -> (
    client: Int32,
    server: Int32
) {
    var descriptors = [Int32](repeating: -1, count: 2)
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
        throw DatabaseBrokerSocketError.unavailable
    }
    do {
        for descriptor in descriptors {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw DatabaseBrokerSocketError.unavailable
            }
        }
        return (descriptors[0], descriptors[1])
    } catch {
        Darwin.close(descriptors[0])
        Darwin.close(descriptors[1])
        throw error
    }
}

private func databaseBrokerCommandTransportDependencies(
    monotonicNanoseconds: @escaping @Sendable () -> UInt64 = {
        DispatchTime.now().uptimeNanoseconds
    }
) -> DatabaseBrokerHealthTransportDependencies {
    DatabaseBrokerHealthTransportDependencies(
        monotonicNanoseconds: monotonicNanoseconds,
        authenticatePeer: { _, _, _ in .authenticated },
        wait: { descriptor, interest, maximumWaitNanoseconds in
            var value = pollfd(
                fd: descriptor,
                events: interest == .readable ? Int16(POLLIN) : Int16(POLLOUT),
                revents: 0)
            let milliseconds = maximumWaitNanoseconds / 1_000_000
            let rounded = milliseconds + (maximumWaitNanoseconds % 1_000_000 == 0 ? 0 : 1)
            let result = Darwin.poll(
                &value,
                1,
                Int32(min(rounded, UInt64(Int32.max))))
            if result == 0 { return .timedOut }
            if result < 0 {
                if errno == EINTR { return .interrupted }
                throw DatabaseBrokerSocketError.unavailable
            }
            let requested = interest == .readable ? Int16(POLLIN) : Int16(POLLOUT)
            if value.revents & requested != 0 { return .ready }
            if value.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                return .disconnected
            }
            throw DatabaseBrokerSocketError.unavailable
        },
        read: { descriptor, maximumByteCount, deadline in
            try DatabaseBrokerHealthTransportDependencies.readFromSocket(
                socketDescriptor: descriptor,
                maximumByteCount: maximumByteCount,
                posixIO: .live,
                deadlineNanoseconds: deadline,
                monotonicNanoseconds: monotonicNanoseconds)
        },
        write: { descriptor, data, offset, deadline in
            try DatabaseBrokerHealthTransportDependencies.writeToSocket(
                socketDescriptor: descriptor,
                data: data,
                offset: offset,
                posixIO: .live,
                deadlineNanoseconds: deadline,
                monotonicNanoseconds: monotonicNanoseconds)
        })
}
