import Darwin
import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

#if EDITH_FUNCTIONAL_FIXTURE
@Suite(.serialized) @MainActor struct HostRemoteFixtureReplyTests {
    @Test(arguments: [false, true])
    func emittedReplyIsObservedAfterActualReplyCallback(fail: Bool) async throws {
        let peer = try HostRemoteProcessIdentity.read(getpid())
        let kernel = try HostRemoteKernelIdentity.read(getpid())
        let request = ExtensionEngineRequest(presentationID: UUID(), operation: "synthetic.observe")
        var emitted: Data?
        var observed = 0
        HostRemoteSession.fixtureObserveNativeReply = { event in
            #expect(event.invocation.ui == peer)
            #expect(event.invocation.receiver == kernel)
            #expect(event.invocation.request.token == request.token)
            #expect(event.reply.token == request.token)
            #expect(event.reply.ok == !fail)
            #expect(event.encodedReply == emitted)
            observed += 1
        }
        defer { HostRemoteSession.fixtureObserveNativeReply = nil }
        let receiver = HostRemoteEngineReceiver(
            receive: { _ in },
            execute: { actual in
                #expect(actual.token == request.token)
                if fail { throw HostWorkerError.rejected }
                return Data("{}".utf8)
            })
        receiver.authenticate(peer)
        let data = try ExtensionEngineWire.encode(request)
        let bytes: Data = await withCheckedContinuation { continuation in
            receiver.invoke(data) { bytes in
                emitted = bytes
                continuation.resume(returning: bytes)
            }
        }
        #expect(observed == 1)
        let reply = try ExtensionEngineWire.decode(ExtensionEngineReply.self, from: bytes)
        #expect(reply.token == request.token)
        #expect(reply.ok == !fail)
    }

    @Test func missingReplyObserverRejectsBeforeOwnerInvocation() async throws {
        HostRemoteSession.fixtureObserveNativeReply = nil
        let request = ExtensionEngineRequest(presentationID: UUID(), operation: "synthetic.observe")
        let receiver = HostRemoteEngineReceiver(
            receive: { _ in },
            execute: { _ in
                Issue.record("An owner was invoked without a source-bound reply observer")
                return Data("{}".utf8)
            })
        receiver.authenticate(try HostRemoteProcessIdentity.read(getpid()))
        let data = try ExtensionEngineWire.encode(request)
        let bytes: Data = await withCheckedContinuation { continuation in
            receiver.invoke(data) { continuation.resume(returning: $0) }
        }
        let reply = try ExtensionEngineWire.decode(ExtensionEngineReply.self, from: bytes)
        #expect(!reply.ok)
        #expect(reply.token == request.token)
    }
}
#endif
