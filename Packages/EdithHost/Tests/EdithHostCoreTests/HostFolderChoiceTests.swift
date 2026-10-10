import Foundation
import Testing

@testable import EdithHostCore

@Suite @MainActor struct HostFolderChoiceTests {
    private func configuration(id: String = "herdr", version: String = "1") throws
        -> HostWorkerConfiguration
    {
        let data = try JSONSerialization.data(withJSONObject: [
            "identifier": "com.example.synthetic.folder",
            "supportDirectory": "file:///tmp/synthetic-folder",
            "extensionID": id, "version": version, "theme": "accent", "appearance": "system",
            "zoom": 1, "recoveryOnly": false,
        ])
        return try JSONDecoder().decode(HostWorkerConfiguration.self, from: data)
    }

    @Test func selectedPathRoundTripsThroughExactSelectorAndWire() throws {
        let config = try configuration()
        var sent: HostWorkerNavigationRequest?
        var output: NSDictionary?
        let client = HostFolderChoiceNavigationClient(
            configuration: config, available: { true }, send: { sent = $0 }, cancel: { _ in })
        #expect(client.responds(to: NSSelectorFromString("chooseFolder:completion:")))
        let presentation = UUID()
        let token = client.chooseFolder(["presentationID": presentation.uuidString]) {
            result, error in
            #expect(error == nil)
            output = result
        }
        let request = try #require(sent)
        #expect(token == request.token.uuidString as NSString)
        #expect(request.presentationID == presentation)
        #expect(request.folderChoice == true)
        try request.validate(configuration: config)
        let reply = HostWorkerNavigationReply(
            request: request, ok: true, folderResult: .init(selectedPath: "/tmp/Synthetic Folder"))
        let decoded = try JSONDecoder().decode(
            HostWorkerNavigationReply.self, from: JSONEncoder().encode(reply))
        try client.receive(decoded)
        #expect(output?["selectedPath"] as? String == "/tmp/Synthetic Folder")
        #expect(output?.count == 1)
        #expect(client.pendingRequestCount == 0)
    }

    @Test func userCancellationIsDistinctFromRejectedTransport() throws {
        var sent: HostWorkerNavigationRequest?
        var cancelled: Bool?
        let client = HostFolderChoiceNavigationClient(
            configuration: try configuration(), available: { true }, send: { sent = $0 },
            cancel: { _ in })
        _ = client.chooseFolder(["presentationID": UUID().uuidString]) { result, error in
            #expect(error == nil)
            cancelled = result?["cancelled"] as? Bool
        }
        try client.receive(
            .init(request: try #require(sent), ok: true, folderResult: .init(cancelled: true)))
        #expect(cancelled == true)
    }

    @Test func disableHiddenAndShutdownDrainOnceAndIgnoreLateChoice() throws {
        for shutdown in [false, true] {
            var sent: HostWorkerNavigationRequest?
            var cancellations = 0
            var completions = 0
            let client = HostFolderChoiceNavigationClient(
                configuration: try configuration(), available: { true }, send: { sent = $0 },
                cancel: { _ in cancellations += 1 })
            _ = client.chooseFolder(["presentationID": UUID().uuidString]) { result, error in
                #expect(result == nil)
                #expect(error != nil)
                completions += 1
            }
            if shutdown { client.invalidate() } else { client.cancelPending() }
            client.cancelPending()
            try client.receive(
                .init(
                    request: try #require(sent), ok: true,
                    folderResult: .init(selectedPath: "/tmp/mock")))
            #expect(cancellations == 1)
            #expect(completions == 1)
        }
    }

    @Test func staleVersionAndInactiveOwnerCannotComplete() throws {
        let config = try configuration()
        var active = true
        var sent: HostWorkerNavigationRequest?
        var completions = 0
        let client = HostFolderChoiceNavigationClient(
            configuration: config, available: { active }, send: { sent = $0 }, cancel: { _ in })
        _ = client.chooseFolder(["presentationID": UUID().uuidString]) { result, error in
            #expect(result == nil && error != nil)
            completions += 1
        }
        let request = try #require(sent)
        let stale = HostWorkerNavigationRequest(
            token: request.token, configuration: try configuration(version: "old"),
            section: "agentActivity",
            presentationID: request.presentationID, location: "settings", folderChoice: true)
        #expect(throws: HostWorkerError.invalidResponse) {
            try client.receive(
                .init(request: stale, ok: true, folderResult: .init(selectedPath: "/tmp/mock")))
        }
        #expect(completions == 0)
        active = false
        try client.receive(
            .init(request: request, ok: true, folderResult: .init(selectedPath: "/tmp/mock")))
        #expect(completions == 1)
    }

    @Test func closedInputsAndBoundedAbsolutePathsReject() throws {
        var sends = 0
        let client = HostFolderChoiceNavigationClient(
            configuration: try configuration(), available: { true }, send: { _ in sends += 1 },
            cancel: { _ in })
        for input: NSDictionary in [
            ["presentationID": "bad"], ["presentationID": 1],
            ["presentationID": UUID().uuidString, "path": "/tmp/mock"], [:],
        ] {
            let token = client.chooseFolder(input) { result, error in
                #expect(result == nil && error != nil)
            }
            #expect(token == nil)
        }
        #expect(sends == 0)
        for path in [
            "relative", "/tmp/../mock", "/tmp/./mock", "/tmp/\0mock",
            "/" + String(repeating: "a", count: 4096),
        ] {
            #expect(throws: HostWorkerError.invalidResponse) {
                try HostFolderChoiceResult(selectedPath: path).validate()
            }
        }
        #expect(throws: HostWorkerError.invalidResponse) {
            try HostFolderChoiceResult(cancelled: false).validate()
        }
        #expect(throws: HostWorkerError.invalidResponse) {
            try HostFolderChoiceResult(selectedPath: "/tmp/mock", cancelled: true).validate()
        }
        let request = HostWorkerNavigationRequest(
            configuration: try configuration(id: "music"),
            section: "agentActivity", presentationID: UUID(), location: "settings",
            folderChoice: true)
        #expect(throws: HostWorkerError.invalidResponse) {
            try request.validate(configuration: try configuration(id: "music"))
        }
    }
}
