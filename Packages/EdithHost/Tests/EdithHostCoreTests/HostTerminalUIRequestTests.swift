import Darwin
import Foundation
import Testing

@testable import EdithHostCore

@MainActor struct HostTerminalUIRequestTests {
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
