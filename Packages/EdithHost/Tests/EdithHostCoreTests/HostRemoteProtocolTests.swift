import Foundation
import Testing
@testable import EdithHostCore

struct HostRemoteProtocolTests {
    @Test func presentationKeepsEachSceneContextSeparate() throws {
        let session = UUID()
        let first = HostExtensionContentRequest(
            extensionID: "database", location: "main", section: "Database")
        let second = HostExtensionContentRequest(
            extensionID: "database", location: "settings", section: "extension")
        let presentation = HostRemotePresentation(
            session: session, request: first, compact: true, visible: false, availableWidth: 540)
        let decoded = try HostRemoteWire.decode(
            HostRemotePresentation.self, from: HostRemoteWire.encode(presentation))
        #expect(decoded == presentation)
        #expect(first.presentationID != second.presentationID)
        try decoded.validate(session: session, extensionID: "database")
        #expect(throws: HostWorkerError.rejected) {
            try decoded.validate(session: UUID(), extensionID: "database")
        }
        #expect(throws: HostWorkerError.rejected) {
            try decoded.validate(session: session, extensionID: "music")
        }
    }

    @Test func malformedScenesAndUnboundedMessagesFailClosed() throws {
        for location in ["", "shell", "../../", "main\0"] {
            let request = HostExtensionContentRequest(extensionID: "database", location: location)
            #expect(throws: HostWorkerError.rejected) {
                try request.validate(extensionID: "database")
            }
        }
        let request = HostExtensionContentRequest(
            extensionID: "database", location: "main", section: String(repeating: "a", count: 129))
        #expect(throws: HostWorkerError.rejected) { try request.validate(extensionID: "database") }
        #expect(throws: HostWorkerError.invalidResponse) {
            try HostRemoteWire.decode(
                HostExtensionContentRequest.self,
                from: Data(repeating: 32, count: HostRemoteWire.maximumBytes + 1))
        }
        #expect(throws: HostWorkerError.invalidResponse) {
            try HostRemoteWire.encode(String(repeating: "x", count: HostRemoteWire.maximumBytes))
        }
    }

    @Test func sceneWidthRequiresFiniteBoundedDimensions() throws {
        let session = UUID()
        let request = HostExtensionContentRequest(extensionID: "music", location: "music.footer")
        for width in [-1.0, .infinity, .nan, 16_385] {
            let scene = HostRemotePresentation(
                session: session, request: request, compact: false, visible: true,
                availableWidth: width)
            #expect(throws: HostWorkerError.rejected) {
                try scene.validate(session: session, extensionID: "music")
            }
        }
    }
}
