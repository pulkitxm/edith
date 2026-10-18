import Darwin
import Foundation
import Testing

@testable import EdithHostCore

@MainActor struct HostTerminalUIRequestTests {
    @Test func signedAnonymousChannelDeliversOnlyTheCurrentFixedTerminalEvent() async throws {
        let identity = try HostRemoteProcessIdentity.read(getpid())
        let session = UUID()
        let request = HostExtensionContentRequest(extensionID: "terminal", location: "main")
        var delivered: [HostTerminalUIEvent] = []
        let requirement =
            "cdhash H\"\(identity.codeHash.map { String(format: "%02x", $0) }.joined())\""
        let server = try HostRemoteEndpoint(
            executable: identity.executable, requirement: requirement,
            execute: { command in
                let value = try HostTerminalUIRequest.decode(
                    command.payload, session: session, request: request,
                    operation: command.operation)
                if let event = value.event {
                    delivered.append(event)
                    return Data("{\"ok\":true}".utf8)
                }
                return try JSONEncoder().encode(
                    HostTerminalUIStatus(presentationID: request.presentationID, focused: true))
            })
        defer { server.invalidate() }
        var endpoint: NSXPCListenerEndpoint?
        server.endpoint { endpoint = $0 }
        let channel = try await HostRemoteChannel.connect(
            to: #require(endpoint), executable: identity.executable, expectedPeer: identity)
        defer { channel.invalidate() }
        let event = HostTerminalUIEvent(
            presentationID: request.presentationID, sequence: 1, active: false, key: false,
            visible: false)
        let input = HostTerminalUIRequest(
            session: session, request: request, operation: .update, event: event)
        let reply = try await channel.request(
            HostRemoteCommand(operation: "terminalUI", payload: input.encoded()))
        #expect(reply.payload == Data("{\"ok\":true}".utf8))
        #expect(delivered == [event])
        let status = HostTerminalUIRequest(session: session, request: request, operation: .status)
        let statusReply = try await channel.request(
            HostRemoteCommand(operation: "terminalUIStatus", payload: status.encoded()))
        #expect(
            try HostTerminalUIStatus.decode(
                statusReply.payload, presentationID: request.presentationID
            ).focused)
        let stale = HostTerminalUIRequest(
            session: UUID(), request: request, operation: .update, event: event)
        await #expect(throws: HostWorkerError.rejected) {
            try await channel.request(
                HostRemoteCommand(operation: "terminalUI", payload: stale.encoded()))
        }
        let foreignRequest = HostExtensionContentRequest(extensionID: "terminal", location: "main")
        let foreign = HostTerminalUIRequest(
            session: session, request: foreignRequest, operation: .status)
        await #expect(throws: HostWorkerError.rejected) {
            try await channel.request(
                HostRemoteCommand(operation: "terminalUIStatus", payload: foreign.encoded()))
        }
        await #expect(throws: HostWorkerError.rejected) {
            try await channel.request(
                HostRemoteCommand(operation: "terminalUIStatus", payload: input.encoded()))
        }
        await #expect(throws: HostWorkerError.rejected) {
            try await channel.request(
                HostRemoteCommand(operation: "execute", payload: status.encoded()))
        }
        #expect(delivered == [event])
    }

    @Test func foreignOwnerOversizeForgedEventAndStatusCannotEnterTheScene() throws {
        let session = UUID()
        let request = HostExtensionContentRequest(extensionID: "terminal", location: "main")
        let status = HostTerminalUIRequest(session: session, request: request, operation: .status)
        for data in [Data(), Data(repeating: 0, count: 2049)] {
            #expect(throws: HostWorkerError.rejected) {
                try HostTerminalUIRequest.decode(
                    data, session: session, request: request, operation: "terminalUIStatus")
            }
        }
        for owner in ["music", "machines"] {
            let foreign = HostTerminalUIRequest(
                session: session,
                request: HostExtensionContentRequest(extensionID: owner, location: "main"),
                operation: .status)
            #expect(throws: HostWorkerError.rejected) { try foreign.encoded() }
        }
        let settings = HostTerminalUIRequest(
            session: session,
            request: HostExtensionContentRequest(extensionID: "terminal", location: "settings"),
            operation: .status)
        #expect(throws: HostWorkerError.rejected) { try settings.encoded() }
        let forged = HostTerminalUIRequest(
            session: session, request: request, operation: .update,
            event: HostTerminalUIEvent(
                presentationID: UUID(), sequence: 2, active: false, key: false, visible: false))
        #expect(throws: HostWorkerError.rejected) { try forged.encoded() }
        let bytes = try JSONEncoder().encode(
            HostTerminalUIStatus(presentationID: UUID(), focused: true))
        #expect(throws: HostWorkerError.invalidResponse) {
            try HostTerminalUIStatus.decode(bytes, presentationID: request.presentationID)
        }
        var fields = try #require(
            JSONSerialization.jsonObject(with: status.encoded()) as? [String: Any])
        fields["operation"] = "readFile"
        #expect(throws: (any Error).self) {
            try HostTerminalUIRequest.decode(
                JSONSerialization.data(withJSONObject: fields), session: session, request: request,
                operation: "terminalUIStatus")
        }
    }
}
