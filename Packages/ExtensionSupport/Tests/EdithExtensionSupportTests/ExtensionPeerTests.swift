import Darwin
import Foundation
import Network
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

    @MainActor @Test func socketCommandsSupportMaximumPayloadsAndFreshRestarts() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = try ExtensionPeerEndpoint(
            namespace: UUID().uuidString, owner: "fixture", directory: directory)
        let payload = Data(repeating: 255, count: ExtensionPeerEndpoint.maximumPayloadBytes)
        for _ in 0..<3 {
            let server = ExtensionPeerServer(endpoint: endpoint) { _, _, payload in payload }
            try server.start()
            defer { server.shutdown() }
            #expect(
                try await endpoint.invoke("echo", payload: Data("fixture".utf8))
                    == Data("fixture".utf8))
            #expect(try await endpoint.invoke("echo", payload: payload) == payload)
            server.shutdown()
            await #expect(throws: ExtensionPeerError.self) { try await endpoint.invoke("echo") }
        }
    }

    @MainActor @Test func socketDisconnectCancelsOwnedCommandAndDeadlineAllowsRecovery()
        async throws
    {
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = try ExtensionPeerEndpoint(
            namespace: UUID().uuidString, owner: "fixture", directory: directory)
        let started = AsyncStream<Void>.makeStream()
        let cancelled = AsyncStream<Void>.makeStream()
        let server = ExtensionPeerServer(endpoint: endpoint) { _, command, payload in
            if command == "wait" {
                started.continuation.yield(())
                do { try await Task.sleep(for: .seconds(30)) } catch {
                    cancelled.continuation.yield(()); throw error
                }
            }
            return payload
        }
        try server.start()
        defer { server.shutdown() }
        var start = started.stream.makeAsyncIterator()
        var cancellation = cancelled.stream.makeAsyncIterator()
        let call = Task { try await endpoint.invoke("wait") }
        _ = await start.next()
        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
        _ = await cancellation.next()
        let expired = Task { try await endpoint.invoke("wait", timeout: 0.2) }
        _ = await start.next()
        await #expect(throws: ExtensionPeerError.self) { try await expired.value }
        _ = await cancellation.next()
        #expect(
            try await endpoint.invoke("echo", payload: Data("recovered".utf8))
                == Data("recovered".utf8))
    }

    @MainActor @Test func cancellationDuringSocketAdmissionRemainsRecoverable() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = try ExtensionPeerEndpoint(
            namespace: UUID().uuidString, owner: "fixture", directory: directory)
        let server = ExtensionPeerServer(endpoint: endpoint) { _, command, payload in
            if command == "wait" { try await Task.sleep(for: .seconds(30)) }
            return payload
        }
        try server.start()
        defer { server.shutdown() }
        for iteration in 0..<128 {
            let call = Task { try await endpoint.invoke("wait", timeout: 1) }
            if iteration.isMultiple(of: 2) {
                await Task.yield()
            } else {
                try await Task.sleep(for: .microseconds(100))
            }
            call.cancel()
            await #expect(throws: CancellationError.self) { try await call.value }
        }
        server.shutdown()
        try server.start()
        #expect(
            try await endpoint.invoke("echo", payload: Data("recovered".utf8))
                == Data("recovered".utf8))
    }

    @MainActor @Test func shutdownDisconnectsAllPendingSocketCommands() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = try ExtensionPeerEndpoint(
            namespace: UUID().uuidString, owner: "fixture", directory: directory)
        let started = AsyncStream<Void>.makeStream()
        let server = ExtensionPeerServer(endpoint: endpoint) { _, _, _ in
            started.continuation.yield(())
            try await Task.sleep(for: .seconds(30))
            return Data()
        }
        try server.start()
        defer { server.shutdown() }
        let call = Task { try await endpoint.invoke("wait") }
        var start = started.stream.makeAsyncIterator()
        _ = await start.next()
        server.shutdown()
        await #expect(throws: ExtensionPeerError.self) { try await call.value }
    }

    @MainActor @Test func socketCapacityRejectsExcessCommandsAndRecovers() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = try ExtensionPeerEndpoint(
            namespace: UUID().uuidString, owner: "fixture", directory: directory)
        let started = AsyncStream<Void>.makeStream()
        let server = ExtensionPeerServer(endpoint: endpoint) { _, command, payload in
            if command == "wait" {
                started.continuation.yield(())
                try await Task.sleep(for: .seconds(30))
            }
            return payload
        }
        try server.start()
        defer { server.shutdown() }
        let calls = (0..<8).map { _ in Task { try await endpoint.invoke("wait") } }
        var iterator = started.stream.makeAsyncIterator()
        for _ in calls { _ = await iterator.next() }
        await #expect(throws: ExtensionPeerError.self) { try await endpoint.invoke("echo") }
        for call in calls { call.cancel() }
        for call in calls {
            await #expect(throws: CancellationError.self) { try await call.value }
        }
        server.shutdown()
        try server.start()
        #expect(
            try await endpoint.invoke("echo", payload: Data("recovered".utf8))
                == Data("recovered".utf8))
    }

    @MainActor @Test func malformedAndOversizedSocketFramesNeverExecute() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = try ExtensionPeerEndpoint(
            namespace: UUID().uuidString, owner: "fixture", directory: directory)
        var executed = 0
        let server = ExtensionPeerServer(endpoint: endpoint) { _, _, payload in
            executed += 1
            return payload
        }
        try server.start()
        defer { server.shutdown() }
        let registration = try #require(
            ExtensionPeerRegistration.read(
                at: endpoint.registrationURL, logicalName: endpoint.name))
        for frame in [
            Data([255, 255, 255, 255]), Data([0, 0, 0, 0]),
            Data([0, 0, 0, 5]) + Data("wrong".utf8),
        ] {
            let connection = NWConnection(
                to: .unix(path: ExtensionPeerSocket.path(registration.physicalName)), using: .tcp)
            connection.start(queue: .global(qos: .utility))
            defer { connection.cancel() }
            connection.send(content: frame, completion: .contentProcessed { _ in })
            await #expect(throws: ExtensionPeerError.self) {
                try await withCheckedThrowingContinuation { continuation in
                    ExtensionPeerFrame.receive(from: connection) { continuation.resume(with: $0) }
                }
            }
        }
        #expect(executed == 0)
        #expect(
            try await endpoint.invoke("echo", payload: Data("recovered".utf8))
                == Data("recovered".utf8))
        #expect(executed == 1)
    }

    @Test func restartingRemovesOnlyADeadWorkersSocket() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = try ExtensionPeerEndpoint(
            namespace: UUID().uuidString, owner: "fixture", directory: directory)
        let lease = try ExtensionPeerRegistrationLease(endpoint: endpoint)
        defer { lease.release() }
        try ExtensionPeerSocket.prepare()
        let path = ExtensionPeerSocket.path(lease.registration.physicalName)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        let listener = try NWListener(using: parameters)
        defer { listener.cancel(); unlink(path) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: .global(qos: .utility))
        try #require(ready.wait(timeout: .now() + 3) == .success)
        let stale = ExtensionPeerRegistration(
            logicalName: endpoint.name, physicalName: lease.registration.physicalName,
            process: ExtensionProcessIdentity(
                pid: getpid(), generation: lease.registration.process.generation + ".expired"))
        try JSONEncoder().encode(stale).write(to: endpoint.registrationURL)
        lease.release()
        #expect(FileManager.default.fileExists(atPath: path))
        let replacement = try ExtensionPeerRegistrationLease(endpoint: endpoint)
        defer { replacement.release() }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func commandFramesRemainBoundedAndSocketPathsFitSystemLimits() throws {
        let payload = Data(repeating: 255, count: ExtensionPeerEndpoint.maximumPayloadBytes)
        let frame = try ExtensionPeerFrame.encode(
            ExtensionPeerRequest(
                token: UUID(), command: "echo", payload: payload, timeout: 30))
        let size = frame.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        #expect(size == frame.count - 4)
        #expect(size <= ExtensionPeerEndpoint.maximumMessageBytes)
        let request = try JSONDecoder().decode(ExtensionPeerRequest.self, from: frame.dropFirst(4))
        #expect(request.payload == payload)
        let path = ExtensionPeerSocket.path(String(repeating: "x", count: 256))
        #expect(path.utf8.count < 104)
        #expect(path.hasPrefix(ExtensionPeerSocket.directory.path + "/"))
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

    @Test func rejectedRegistrationLeasesCannotCloseConcurrentFileWriters() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = try ExtensionPeerEndpoint(
            namespace: "fixture", owner: "lock-contention", directory: directory)
        let owner = try ExtensionPeerRegistrationLease(endpoint: endpoint)
        defer { owner.release() }
        try owner.publish()
        let target = directory.appendingPathComponent("writer.json")
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await BlockingWork.perform {
                    for _ in 0..<1_000 {
                        do {
                            let rejected = try ExtensionPeerRegistrationLease(endpoint: endpoint)
                            rejected.release()
                            Issue.record("An active registration lease must remain exclusive.")
                        } catch ExtensionPeerError.unavailable {}
                    }
                }
            }
            group.addTask {
                try await BlockingWork.perform {
                    for index in 0..<1_000 {
                        try Data("{\"fixture\":\(index)}".utf8).write(to: target, options: .atomic)
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(
            ExtensionPeerRegistration.read(
                at: endpoint.registrationURL, logicalName: endpoint.name)?.physicalName
                == owner.registration.physicalName)
        #expect(try Data(contentsOf: target) == Data("{\"fixture\":999}".utf8))
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
