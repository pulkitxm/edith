import Darwin
import EdithExtensionSupport
import Foundation
import Testing
@testable import EdithHostCore

@MainActor @Suite(.serialized) struct HostCLITransportTests {
    private func identity() throws -> HostIdentity {
        try HostIdentity(
            identifier: "com.pulkit.edith.tests.cli-\(UUID().uuidString)",
            supportDirectory: FileManager.default.temporaryDirectory)
    }
    @Test func authenticatedRoundTripAndSingletonOwnership() async throws {
        let identity = try identity()
        let server = HostCLIServer(identity: identity) { $0.payload }
        try server.start()
        defer { server.shutdown() }
        let duplicate = HostCLIServer(identity: identity) { $0.payload }
        #expect(throws: HostCLIError.self) { try duplicate.start() }
        let request = try HostCLIRequest(
            action: .invoke, id: "sample", operation: "echo",
            payload: Data("{\"synthetic\":true}".utf8))
        let result = try await Task.detached {
            try HostCLITransport.invoke(request, identity: identity)
        }.value
        #expect(result == request.payload)
    }
    @Test func maximumEnginePayloadAndStdinRoundTripOverAuthenticatedSocket() async throws {
        let identity = try identity()
        let server = HostCLIServer(identity: identity) { $0.payload }
        try server.start()
        defer { server.shutdown() }
        let payload = Data(
            ("\"" + String(repeating: "?", count: HostCLIRequest.maximumPayload - 2) + "\"").utf8)
        let maximum = try HostCLIRequest(
            action: .invoke, id: "synthetic", operation: "synthetic.echo", payload: payload)
        #expect(
            try await Task.detached { try HostCLITransport.invoke(maximum, identity: identity) }
                .value == payload)
        let input = Data(repeating: 0xFF, count: ExtensionCLIRequest.maximumInputBytes)
        let context = try ExtensionCLIRequest(
            arguments: ["ls", "--json"], standardInput: input,
            workingDirectory: "/tmp/synthetic-caller", interactive: true)
        guard
            case .terminal(let request) = try HostCLICommand.parse(
                ["calendar", "ls", "--json"], standardInput: input,
                workingDirectory: context.workingDirectory, interactive: true)
        else { Issue.record("Calendar context missing"); return }
        let result = try await Task.detached {
            try HostCLITransport.invoke(request, identity: identity)
        }.value
        #expect(try JSONDecoder().decode(ExtensionCLIRequest.self, from: result) == context)
    }

    @Test func malformedResponsesRejectInvalidPayloadAndNumericExitCodes() throws {
        for object: [String: Any] in [
            ["exitCode": 0, "payload": "invalid!"],
            ["exitCode": true, "payload": "e30="],
            ["exitCode": 0.5, "payload": "e30="],
            ["exitCode": 4_294_967_296.0, "payload": "e30="],
            ["exitCode": 0, "payload": "e30=", "error": "conflicting"],
            ["exitCode": 1, "payload": "e30="],
            ["exitCode": 0], ["exitCode": 0, "payload": "e30=", "unexpected": true],
        ] {
            #expect(throws: HostCLIError.self) {
                try HostCLIResponse.decoded(JSONSerialization.data(withJSONObject: object))
            }
        }
        let oversized = try JSONSerialization.data(withJSONObject: [
            "exitCode": 0,
            "payload": Data(count: HostCLIRequest.maximumPayload + 1).base64EncodedString(),
        ])
        #expect(throws: HostCLIError.self) { try HostCLIResponse.decoded(oversized) }
    }

    @Test func malformedAndTruncatedFramesCloseOnlyOwnedConnections() throws {
        for length: UInt32 in [0, UInt32(HostCLITransport.maximumRequest + 1), 16] {
            var descriptors = [Int32](repeating: -1, count: 2)
            #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
            let input = HostCLIConnection(descriptors[0])
            let output = HostCLIConnection(descriptors[1])
            defer { input.close(); output.close() }
            var header = length.bigEndian
            #expect(
                withUnsafeBytes(of: &header) {
                    Darwin.write(output.descriptor, $0.baseAddress!, $0.count)
                } == 4)
            output.cancel()
            #expect(throws: HostCLIError.self) {
                try input.read(limit: HostCLITransport.maximumRequest)
            }
            input.close()
            #expect(fcntl(input.descriptor, F_GETFD) == -1 && errno == EBADF)
        }
    }

    @Test func cancellingAReadDrainsAndClosesTheExactSocket() async throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let input = HostCLIConnection(descriptors[0])
        let output = HostCLIConnection(descriptors[1])
        defer { input.close(); output.close() }
        let reading = Task.detached { try input.read(limit: 16) }
        input.cancel()
        await #expect(throws: HostCLIError.self) { try await reading.value }
        input.close()
        #expect(fcntl(input.descriptor, F_GETFD) == -1 && errno == EBADF)
        #expect(fcntl(output.descriptor, F_GETFD) != -1)
    }

    @Test func timeoutCancelsWorkAndKeepsControlResponsive() async throws {
        let identity = try identity()
        var cancelled = false
        let server = HostCLIServer(identity: identity) { request in
            if request.action == .invoke {
                do { try await Task.sleep(for: .seconds(30)) } catch {
                    cancelled = true; throw error
                }
            }
            return Data("{}".utf8)
        }
        try server.start()
        defer { server.shutdown() }
        let request = try HostCLIRequest(
            action: .invoke, id: "sample", operation: "wait", timeout: 1)
        let failure = await Task.detached { () -> Int32 in
            do { _ = try HostCLITransport.invoke(request, identity: identity); return 0 } catch {
                return (error as? HostCLIError)?.exitCode ?? 99
            }
        }.value
        #expect(failure == 4)
        for _ in 0..<20 where !cancelled { try await Task.sleep(for: .milliseconds(10)) }
        #expect(cancelled)
        let list = try HostCLIRequest(action: .ls)
        #expect(
            try await Task.detached { try HostCLITransport.invoke(list, identity: identity) }.value
                == Data("{}".utf8))
    }
    @Test func oversizedFramesAreRejectedBeforeReadingTheirBody() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let connection = HostCLIConnection(descriptors[0])
        defer { connection.close(); Darwin.close(descriptors[1]) }
        var length = UInt32(HostCLITransport.maximumRequest + 1).bigEndian
        #expect(
            withUnsafeBytes(of: &length) { Darwin.write(descriptors[1], $0.baseAddress!, $0.count) }
                == 4)
        #expect(throws: HostCLIError.self) {
            try connection.read(limit: HostCLITransport.maximumRequest)
        }
    }
    @Test func offlineControlDoesNotCreateAnApplicationOrWorker() throws {
        let identity = try identity()
        #expect(throws: HostCLIError.self) {
            try HostCLITransport.invoke(HostCLIRequest(action: .ls), identity: identity)
        }
        #expect(!FileManager.default.fileExists(atPath: identity.root.path))
    }
    @Test func acceptedNonblockingSocketsWaitForTheRequestBody() async throws {
        var sockets: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        let input = HostCLIConnection(sockets[0])
        let output = HostCLIConnection(sockets[1])
        defer { input.close(); output.close() }
        #expect(fcntl(sockets[0], F_SETFL, O_NONBLOCK) == 0)
        try input.configure(timeout: 2)
        let writer = Task.detached {
            try await Task.sleep(for: .milliseconds(100))
            try output.write(Data("delayed".utf8), limit: 100)
        }
        let value = try await Task.detached { try input.read(limit: 100) }.value
        try await writer.value
        #expect(value == Data("delayed".utf8))
    }

}
