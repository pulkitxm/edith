import Foundation
import Testing

@testable import EdithHostCore

@MainActor
@Suite struct HostMachinesWindowTests {
    @Test func typedTargetPreservesRemoteFilesPathAndRejectsUnownedKindsAndPaths() throws {
        let machine = UUID()
        let target = HostMachinesWindowTarget(
            kind: .files, machineID: machine, path: "/Synthetic/Folder")
        try target.validate()
        let id = UUID()
        let input = try target.context(presentationID: id)
        #expect(input["machineID"] as? String == machine.uuidString)
        #expect(input["presentationID"] as? String == id.uuidString)
        #expect(input["path"] as? String == "/Synthetic/Folder")
        for invalid in [
            HostMachinesWindowTarget(kind: .terminal, machineID: machine, path: "/Synthetic"),
            HostMachinesWindowTarget(
                kind: .files, machineID: machine, path: String(repeating: "x", count: 4097)),
            HostMachinesWindowTarget(kind: .files, machineID: machine, path: "bad\u{0}path"),
        ] { #expect(throws: HostWorkerError.rejected) { try invalid.validate() } }
    }

    @Test func onlyActiveMachinesAuxiliaryScenesCanCarryTheTypedTarget() throws {
        let target = HostMachinesWindowTarget(kind: .docker, machineID: UUID())
        let valid = HostExtensionContentRequest(
            extensionID: "machines", location: "machines.window", section: "machines",
            machinesWindow: target)
        try valid.validate(extensionID: "machines")
        #expect(
            try JSONDecoder().decode(
                HostExtensionContentRequest.self, from: JSONEncoder().encode(valid)) == valid)
        for invalid in [
            HostExtensionContentRequest(
                extensionID: "music", location: "machines.window", section: "machines",
                machinesWindow: target),
            HostExtensionContentRequest(
                extensionID: "machines", location: "main", section: "machines",
                machinesWindow: target),
            HostExtensionContentRequest(
                extensionID: "machines", location: "settings", section: "machines",
                machinesWindow: target),
            HostExtensionContentRequest(
                extensionID: "machines", location: "machines.window", section: "machines"),
            HostExtensionContentRequest(
                extensionID: "machines", location: "machines.window", machinesWindow: target),
        ] {
            #expect(throws: HostWorkerError.rejected) {
                try invalid.validate(extensionID: invalid.extensionID)
            }
        }
    }

    @Test func fixedEngineBridgeWaitsForExactAcknowledgementAndCancelsOwnedRequest() throws {
        let configuration = try configuration()
        var sent: [HostWorkerNavigationRequest] = []
        var cancelled: [UUID] = []
        let client = HostWorkerNavigationClient(
            configuration: configuration, available: { true }, send: { sent.append($0) },
            cancel: { cancelled.append($0.token) })
        let target = HostMachinesWindowTarget(kind: .terminal, machineID: UUID())
        let presentation = UUID()
        var replies: [Bool] = []
        let token = try #require(
            client.openWindow(try target.context(presentationID: presentation)) {
                replies.append($0 == nil)
            })
        #expect(sent.count == 1 && replies.isEmpty)
        let request = try #require(sent.first)
        #expect(request.machinesWindow == target && request.presentationID == presentation)
        #expect(request.location == nil && request.section == nil && request.relativePath == nil)
        try request.validate(configuration: configuration)
        let other = HostWorkerNavigationRequest(configuration: configuration)
        try client.receive(HostWorkerNavigationReply(request: other, ok: true))
        #expect(replies.isEmpty)
        client.cancelNavigation(token)
        #expect(replies == [false] && cancelled == [request.token])
        try client.receive(HostWorkerNavigationReply(request: request, ok: true))
        #expect(replies == [false])
        _ = client.openWindow(try target.context(presentationID: presentation)) {
            replies.append($0 == nil)
        }
        try client.receive(HostWorkerNavigationReply(request: try #require(sent.last), ok: true))
        #expect(replies == [false, true])
        client.invalidate()
    }

    @Test func unknownForeignAndUnboundedObjectiveCInputsNeverReachTheHost() throws {
        var sends = 0; var failures = 0
        let valid = try HostMachinesWindowTarget(kind: .files, machineID: UUID()).context(
            presentationID: UUID())
        let invalid: [NSDictionary] = [
            [
                "kind": "arbitrary", "machineID": UUID().uuidString,
                "presentationID": UUID().uuidString,
            ],
            ["kind": "files", "machineID": "invalid", "presentationID": UUID().uuidString],
            ["kind": "files", "machineID": UUID().uuidString],
            [
                "kind": "files", "machineID": UUID().uuidString,
                "presentationID": UUID().uuidString, "path": String(repeating: "é", count: 2049),
            ],
            [
                "kind": "files", "machineID": UUID().uuidString,
                "presentationID": UUID().uuidString, "command": "anything",
            ],
        ]
        let client = HostWorkerNavigationClient(
            configuration: try configuration(), available: { true }, send: { _ in sends += 1 },
            cancel: { _ in })
        for input in invalid {
            #expect(client.openWindow(input) { if $0 != nil { failures += 1 } } == nil)
        }
        let foreign = HostWorkerNavigationClient(
            configuration: try configuration(id: "music"), available: { true },
            send: { _ in sends += 1 }, cancel: { _ in })
        #expect(foreign.openWindow(valid) { if $0 != nil { failures += 1 } } == nil)
        #expect(sends == 0 && failures == invalid.count + 1)
        client.invalidate(); foreign.invalidate()
    }

    private func configuration(id: String = "machines") throws -> HostWorkerConfiguration {
        try HostWorkerConfiguration(
            identity: HostIdentity(
                identifier: "com.pulkit.edith.tests.machines-window-" + UUID().uuidString,
                supportDirectory: FileManager.default.temporaryDirectory), extensionID: id,
            version: "1.0.0")
    }
}
