import Darwin
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
}
