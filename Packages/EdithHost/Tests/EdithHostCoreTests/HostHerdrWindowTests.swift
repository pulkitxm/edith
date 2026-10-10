import Foundation
import Testing

@testable import EdithHostCore

@MainActor
@Suite(.serialized)
struct HostHerdrWindowTests {
    @Test func descriptorRejectsUnknownFieldsWrongOwnersKindsAndUnboundedSizes() throws {
        let valid = descriptor()
        #expect(try HostHerdrWindowTarget.decode(valid).location == "herdr.agent")
        for change in [
            ["owner": "quinjet"], ["version": 2], ["location": "herdr.agent.controls"],
            ["width": 5000], ["minimumWidth": 1200], ["target": ""], ["surprise": true],
            ["title": String(repeating: "x", count: 4097)], ["target": "bad\u{0}value"],
        ] as [[String: Any]] {
            var object = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
            object.merge(change) { _, new in new }
            #expect(throws: (any Error).self) {
                try HostHerdrWindowTarget.decode(JSONSerialization.data(withJSONObject: object))
            }
        }
    }

    @Test func fixedSelectorPreservesTokenAndWaitsForExactNavigationAcknowledgement() throws {
        let configuration = try configuration()
        var sent: HostWorkerNavigationRequest?
        var success = false
        let client = HostWorkerNavigationClient(
            configuration: configuration, available: { true },
            send: { sent = $0 }, cancel: { _ in })
        let token = UUID()
        let data = descriptor(token: token)
        let presentation = UUID()
        let requestToken = client.openHerdrWindow([
            "presentationID": presentation.uuidString, "descriptor": data,
        ]) { success = $0 == nil }
        #expect(requestToken != nil && !success)
        let request = try #require(sent)
        #expect(request.presentationID == presentation && request.herdrWindow?.token == token)
        try request.validate(configuration: configuration)
        try client.receive(.init(request: request, ok: true))
        #expect(success)
        var rejected = false
        #expect(
            client.openHerdrWindow([
                "presentationID": presentation.uuidString, "descriptor": data,
                "extensionID": "herdr",
            ]) { rejected = $0 != nil } == nil)
        #expect(rejected)
        let foreign = HostWorkerNavigationRequest(
            configuration: try self.configuration(id: "music"),
            presentationID: presentation, herdrWindow: request.herdrWindow)
        #expect(throws: (any Error).self) {
            try foreign.validate(configuration: self.configuration(id: "music"))
        }
        let content = HostExtensionContentRequest(
            extensionID: "herdr", location: "herdr.agent",
            section: "herdr", herdrWindow: request.herdrWindow)
        try content.validate(extensionID: "herdr")
        #expect(throws: HostWorkerError.rejected) {
            try HostExtensionContentRequest(extensionID: "herdr", location: "herdr.agent")
                .validate(extensionID: "herdr")
        }
    }

    @Test func forgedDescriptorCannotAdmitOrCloseAnExistingToken() async throws {
        let original = try HostHerdrWindowTarget.decode(descriptor())
        let changed = try HostHerdrWindowTarget.decode(
            descriptor(token: original.token, target: "foreign"))
        var calls: [String] = []
        let lease = HostHerdrWindowLease(
            target: changed,
            invoke: { operation, _ in
                calls.append(operation)
                return try state(original)
            }, validateOrigin: {})
        await #expect(throws: HostWorkerError.rejected) { try await lease.validate() }
        await #expect(throws: HostWorkerError.rejected) { try await lease.admit() }
        try await lease.close()
        #expect(calls == ["herdr.ui.read"])
    }

    @Test func admissionAndFocusRequireCurrentOriginButCloseDrainsTheRetainedEngine() async throws {
        let target = try HostHerdrWindowTarget.decode(descriptor())
        var available = true
        var presented = false
        var calls: [String] = []
        let lease = HostHerdrWindowLease(
            target: target,
            invoke: { operation, payload in
                calls.append(operation)
                let object = try #require(
                    JSONSerialization.jsonObject(with: payload) as? [String: Any])
                if operation != "herdr.ui.read" {
                    #expect(object["token"] as? String == target.token.uuidString)
                }
                if operation.hasSuffix("admit") { presented = true }
                if operation.hasSuffix("close") { return Data("{\"presentations\":[]}".utf8) }
                return try state(target, presented: presented)
            }, validateOrigin: { if !available { throw HostWorkerError.rejected } })
        try await lease.validate()
        try await lease.admit()
        try await lease.focus(true)
        available = false
        await #expect(throws: HostWorkerError.rejected) { try await lease.focus(false) }
        try await lease.close()
        #expect(
            calls == [
                "herdr.ui.read", "herdr.ui.presentation.admit", "herdr.ui.presentation.focus",
                "herdr.ui.presentation.close",
            ])
    }

    private func descriptor(token: UUID = UUID(), target: String = "synthetic-agent") -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "version": 1, "owner": "herdr", "location": "herdr.agent", "target": target,
            "token": token.uuidString, "title": "Synthetic session", "width": 1000,
            "height": 640, "minimumWidth": 560, "minimumHeight": 360, "presented": false,
        ])
    }
    private func state(_ target: HostHerdrWindowTarget, presented: Bool? = nil) throws -> Data {
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(target)) as? [String: Any])
        if let presented { object["presented"] = presented }
        return try JSONSerialization.data(withJSONObject: ["presentations": [object]])
    }
    private func configuration(id: String = "herdr") throws -> HostWorkerConfiguration {
        .init(
            identity: try HostIdentity(
                identifier: "com.pulkit.edith.tests.herdr-" + UUID().uuidString,
                supportDirectory: FileManager.default.temporaryDirectory), extensionID: id,
            version: "1.0.0")
    }
}
