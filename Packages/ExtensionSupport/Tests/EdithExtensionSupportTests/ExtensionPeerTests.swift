import Darwin
import Foundation
import Testing
@testable import EdithExtensionSupport

@Suite struct ExtensionPeerTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
    @Test func endpointsAreScopedToApplicationAndFeature() throws {
        let first = try ExtensionPeerEndpoint(
            namespace: "fixture.first", owner: "calendar", directory: directory)
        let same = try ExtensionPeerEndpoint(
            namespace: "fixture.first", owner: "calendar", directory: directory)
        let second = try ExtensionPeerEndpoint(
            namespace: "fixture.second", owner: "calendar", directory: directory)
        let other = try ExtensionPeerEndpoint(
            namespace: "fixture.first", owner: "presenter", directory: directory)
        #expect(first.name == same.name)
        #expect(first.name != second.name)
        #expect(first.name != other.name)
        #expect(first.name.utf8.count < 128)
        #expect(throws: ExtensionPeerError.self) {
            try ExtensionPeerEndpoint(namespace: "", owner: "calendar", directory: directory)
        }
        #expect(throws: ExtensionPeerError.self) {
            try ExtensionPeerEndpoint(
                namespace: "fixture", owner: "calendar/../../outside", directory: directory)
        }
    }

    @Test func missingPeerFailsWithoutWaitingForCommandDeadline() async throws {
        let endpoint = try ExtensionPeerEndpoint(
            namespace: UUID().uuidString, owner: "missing", directory: directory)
        let start = ContinuousClock.now
        await #expect(throws: ExtensionPeerError.self) {
            try await endpoint.invoke("echo", timeout: 30)
        }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func invalidCommandsFailBeforeOpeningTransport() async throws {
        let endpoint = try ExtensionPeerEndpoint(
            namespace: UUID().uuidString, owner: "fixture", directory: directory)
        for command in ["", "bad\0command", String(repeating: "x", count: 257)] {
            await #expect(throws: ExtensionPeerError.self) {
                try await endpoint.invoke(command)
            }
        }
        for timeout in [0.0, -1, .infinity, .nan, 1_801] {
            await #expect(throws: ExtensionPeerError.self) {
                try await endpoint.invoke("echo", timeout: timeout)
            }
        }
        await #expect(throws: ExtensionPeerError.self) {
            try await endpoint.invoke(
                "echo", payload: Data(count: ExtensionPeerEndpoint.maximumPayloadBytes + 1))
        }
    }

    @MainActor @Test func secondServerCannotReplaceAnActiveEndpoint() throws {
        let endpoint = try ExtensionPeerEndpoint(
            namespace: UUID().uuidString, owner: "fixture", directory: directory)
        let first = ExtensionPeerServer(endpoint: endpoint) { _, _, payload in payload }
        let second = ExtensionPeerServer(endpoint: endpoint) { _, _, payload in payload }
        try first.start()
        defer {
            first.shutdown(); second.shutdown(); try? FileManager.default.removeItem(at: directory)
        }
        #expect(throws: ExtensionPeerError.self) { try second.start() }
        first.shutdown()
        try second.start()
    }

    @Test func restartsUseFreshPhysicalPortsAndExclusiveRegistration() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = try ExtensionPeerEndpoint(
            namespace: "fixture", owner: "worker", directory: directory)
        let first = try ExtensionPeerRegistrationLease(endpoint: endpoint)
        try first.publish()
        #expect(
            ExtensionPeerRegistration.read(
                at: endpoint.registrationURL, logicalName: endpoint.name)?.physicalName
                == first.registration.physicalName)
        #expect(throws: ExtensionPeerError.self) {
            try ExtensionPeerRegistrationLease(endpoint: endpoint)
        }
        first.release()
        #expect(!FileManager.default.fileExists(atPath: endpoint.registrationURL.path))
        let second = try ExtensionPeerRegistrationLease(endpoint: endpoint)
        defer { second.release() }
        try second.publish()
        #expect(second.registration.physicalName != first.registration.physicalName)
        #expect(second.registration.physicalName.utf8.count < 128)
    }

    @Test func staleIdentitiesAndLinkedRegistrationFilesCannotSelectAPeer() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = try ExtensionPeerEndpoint(
            namespace: "fixture", owner: "worker", directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identity = try #require(ExtensionProcessIdentity.current)
        let stale = ExtensionPeerRegistration(
            logicalName: endpoint.name, physicalName: "edith.extension.worker.\(getuid()).fixture",
            process: ExtensionProcessIdentity(
                pid: identity.pid, generation: identity.generation + ".old"))
        try JSONEncoder().encode(stale).write(to: endpoint.registrationURL)
        #expect(
            ExtensionPeerRegistration.read(at: endpoint.registrationURL, logicalName: endpoint.name)
                == nil)
        let target = directory.appendingPathComponent("linked.json")
        let live = ExtensionPeerRegistration(
            logicalName: endpoint.name, physicalName: stale.physicalName, process: identity)
        try JSONEncoder().encode(live).write(to: target)
        try FileManager.default.removeItem(at: endpoint.registrationURL)
        try FileManager.default.createSymbolicLink(
            at: endpoint.registrationURL, withDestinationURL: target)
        #expect(
            ExtensionPeerRegistration.read(at: endpoint.registrationURL, logicalName: endpoint.name)
                == nil)
    }

    @MainActor @Test func commandCancellationCompletesOnceDespiteLateResult() async throws {
        let registry = ExtensionCommandRegistry()
        let token = UUID()
        var continuation: CheckedContinuation<Data, Never>?
        var returned = false
        var completions = 0
        registry.invoke(
            ["token": token.uuidString, "command": "wait", "payload": Data()] as NSDictionary,
            completion: { data, message in
                completions += 1
                #expect(data == nil)
                #expect(message != nil)
            }
        ) { _, _ in
            let result = await withCheckedContinuation { continuation = $0 }
            returned = true
            return result
        }
        while continuation == nil { await Task.yield() }
        registry.cancel(token.uuidString)
        #expect(completions == 1)
        continuation?.resume(returning: Data("late".utf8))
        while !returned { await Task.yield() }
        await Task.yield()
        registry.shutdown()
        #expect(completions == 1)
    }

    @MainActor @Test func commandCapacityAndShutdownReleaseEveryRequest() async throws {
        let registry = ExtensionCommandRegistry()
        var completions = 0
        var started = 0
        for _ in 0..<9 {
            registry.invoke(
                ["token": UUID().uuidString, "command": "wait", "payload": Data()] as NSDictionary,
                completion: { data, message in
                    completions += 1
                    #expect(data == nil)
                    #expect(message != nil)
                }
            ) { _, _ in
                started += 1
                try await Task.sleep(for: .seconds(30))
                return Data()
            }
        }
        #expect(completions == 1)
        while started < 8 { await Task.yield() }
        registry.shutdown()
        #expect(completions == 9)
        await Task.yield()
        registry.shutdown()
        #expect(completions == 9)
    }

    @MainActor @Test func invalidBundleRequestsNeverExecute() {
        let registry = ExtensionCommandRegistry()
        var completions = 0
        for request in [
            [:],
            ["token": UUID().uuidString, "command": "", "payload": Data()],
            ["token": "invalid", "command": "echo", "payload": Data()],
        ] as [NSDictionary] {
            registry.invoke(
                request,
                completion: { data, message in
                    completions += 1
                    #expect(data == nil)
                    #expect(message != nil)
                }
            ) { _, _ in
                Issue.record("Invalid requests must not run bundle commands.")
                return Data()
            }
        }
        #expect(completions == 3)
    }
}
