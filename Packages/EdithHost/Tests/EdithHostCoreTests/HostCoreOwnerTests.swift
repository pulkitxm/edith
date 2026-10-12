import Darwin
import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostCoreOwnerTests {
    @Test func controlledOwnerReportsAndCancelsActualWork() async throws {
        let owner = try CoreOwnerFixture()
        defer { owner.stop() }
        let hooks = HostCoreOwnerHooks(invoke: { try await owner.invoke($0) })
        let before = try await hooks.jobs()
        #expect(before.count == 1 && before[0].id == "usage.refresh" && before[0].runCount == 0)
        try await hooks.control(job: "usage.refresh", cancel: false)
        let running = try await hooks.jobs()
        #expect(running[0].phase == .running && running[0].runCount == 1)
        try await hooks.control(job: "usage.refresh", cancel: true)
        let idle = try await hooks.jobs()
        #expect(idle[0].phase == .idle && idle[0].runCount == 1)
        #expect(idle[0].lastDuration ?? 0 > 0)
        #expect(
            try String(contentsOf: owner.root.appendingPathComponent("digest"), encoding: .utf8)
                == "20ad63e82c6f84b64183b794d89ac683ee4bb815a5f55ca26477ef83729137a2")
        #expect(try await hooks.events().map(\.message) == ["Started.", "Cancelled."])
        #expect(try await hooks.logs(last: "10m").last?.contains("Cancelled.") == true)
        let trace = try String(
            contentsOf: owner.root.appendingPathComponent("trace"), encoding: .utf8)
        #expect(trace.contains("\"operation\": \"run\""))
        #expect(trace.contains("\"operation\": \"cancel\""))
    }

    @Test @MainActor func originalReadinessReportsUseActualOwnedFixtureFilesAndDryRunHasNoWrites()
        async throws
    {
        let owner = try CoreOwnerFixture()
        defer { owner.stop() }
        let hooks = HostCoreOwnerHooks(invoke: { try await owner.invoke($0) })
        let cli = HostCoreReadinessCLI(
            backend: .init(
                entries: { [.init(id: "usage", title: "Usage")] },
                inspect: { try await hooks.readiness(id: $0, operation: $1, title: "Usage") },
                setup: { try await hooks.setup(id: $0, dryRun: $1, installTools: $2) }))
        let unhealthy = try await cli.execute(["status", "usage", "--json"])
        #expect(unhealthy.exitCode == 0 && unhealthy.stderr.isEmpty)
        let report = try JSONDecoder().decode(HostCLIJSON.self, from: Data(unhealthy.stdout.utf8))
        #expect(report.object?["verified"] == .bool(false) && report.object?["owner"] == nil)
        #expect(report.object?["state"]?.object?["phase"] == .string("needsSetup"))
        #expect(report.object?["checks"]?.array?.count == 2)
        let dry = try await cli.execute([
            "setup", "usage", "--dry-run", "--install-tools", "--json",
        ])
        let setup = try JSONDecoder().decode(HostCLIJSON.self, from: Data(dry.stdout.utf8))
        #expect(setup.object?["changed"] == .bool(false))
        #expect(setup.object?["plannedTools"] == .strings(["synthetic-tool"]))
        #expect(
            !FileManager.default.fileExists(atPath: owner.root.appendingPathComponent("tool").path))
        let result = try await cli.execute(["setup", "usage", "--install-tools"])
        #expect(result.stdout.hasPrefix("usage already enabled\nusage  Needs setup  Installed"))
        #expect(result.exitCode == 0 && result.stderr.isEmpty)
        #expect(
            FileManager.default.isExecutableFile(
                atPath: owner.root.appendingPathComponent("tool").path))
        try Data("granted".utf8).write(to: owner.root.appendingPathComponent("permission"))
        let ready = try await cli.execute(["verify", "usage", "--json"])
        #expect(ready.stdout.contains("\"verified\": true"))
        #expect(try await cli.execute(["doctor"]).stdout.contains("passed  Required permission"))
        #expect(try await cli.execute(["status"]).stdout.contains("READINESS"))
        let missing = try await cli.execute(["verify", "missing"])
        #expect(missing.exitCode == 3 && missing.stdout.isEmpty)
        await #expect(throws: HostCLIError.self) { try await cli.execute(["verify"]) }
    }

    @Test func missingLiveOriginalOwnerDiagnosticsReturnActionableUnavailability() async throws {
        let owner = try CoreOwnerFixture()
        defer { owner.stop() }
        let hooks = HostCoreOwnerHooks(invoke: { request in
            let data = try await owner.invoke(request)
            guard request.operation == "usage.cli.catalog" else { return data }
            var catalog = try #require(JSONDecoder().decode(HostCLIJSON.self, from: data).object)
            catalog.removeValue(forKey: "coreOwner")
            return try HostCLIJSON.object(catalog).encoded()
        })
        for operation in ["jobs", "events", "logs"] {
            do {
                switch operation {
                case "jobs": _ = try await hooks.jobs()
                case "events": _ = try await hooks.events()
                default: _ = try await hooks.logs(last: "1h")
                }
                Issue.record("Missing original owner hooks were silently omitted.")
            } catch let error as HostCoreCommandFailure {
                #expect(error.code == 4)
                #expect(error.message.contains(operation) && error.message.contains("usage"))
                #expect(error.hint?.contains("Update usage") == true)
            }
        }
        #expect(
            !FileManager.default.fileExists(atPath: owner.root.appendingPathComponent("trace").path)
        )
    }

    @Test func ownerDisableAndWrongAcknowledgementCannotAcknowledgeWork() async throws {
        let owner = try CoreOwnerFixture()
        defer { owner.stop() }
        let hooks = HostCoreOwnerHooks(invoke: { try await owner.invoke($0) })
        owner.disabled = true
        await #expect(throws: HostCoreCommandFailure.self) {
            try await hooks.control(job: "usage.refresh", cancel: false)
        }
        #expect(
            !FileManager.default.fileExists(atPath: owner.root.appendingPathComponent("trace").path)
        )
        owner.disabled = false; owner.forgeAck = true
        await #expect(throws: HostCoreCommandFailure.self) {
            try await hooks.control(job: "usage.refresh", cancel: false)
        }
        owner.forgeAck = false
        try await hooks.control(job: "usage.refresh", cancel: true)
        owner.changeOnReply = true
        await #expect(throws: HostCoreCommandFailure.self) { try await hooks.jobs() }
    }
}

private let digest = "20ad63e82c6f84b64183b794d89ac683ee4bb815a5f55ca26477ef83729137a2"

private final class CoreOwnerFixture: @unchecked Sendable {
    let root: URL
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var disabledValue = false
    private var forgeValue = false
    private var changeValue = false
    var disabled: Bool {
        get { lock.withLock { disabledValue } }
        set { lock.withLock { disabledValue = newValue } }
    }
    var forgeAck: Bool {
        get { lock.withLock { forgeValue } }
        set { lock.withLock { forgeValue = newValue } }
    }
    var changeOnReply: Bool {
        get { lock.withLock { changeValue } }
        set { lock.withLock { changeValue = newValue } }
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "core-owner-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("synthetic controlled input".utf8).write(to: root.appendingPathComponent("input"))
        try Data("missing".utf8).write(to: root.appendingPathComponent("permission"))
        let script = try #require(
            Bundle.module.url(
                forResource: "core-owner", withExtension: "py", subdirectory: "Fixtures"))
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", script.path, root.path]
        process.standardInput = input; process.standardOutput = output;
        process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
    }

    func invoke(_ request: HostCLIRequest) async throws -> Data {
        try Task.checkCancellation()
        return try lock.withLock {
            if request.action == .ls {
                return try HostCLIJSON.array([
                    .object([
                        "id": .string("usage"), "installed": .bool(true), "compatible": .bool(true),
                        "enabled": .bool(!disabledValue), "running": .bool(process.isRunning),
                        "version": .string("1"), "disablePending": .bool(false),
                        "removalPending": .bool(false),
                        "processIdentifier": .integer(Int64(process.processIdentifier)),
                    ])
                ]).encoded()
            }
            guard !disabledValue, request.id == "usage", let operation = request.operation else {
                throw HostCLIError.unavailable
            }
            if operation == "usage.cli.catalog" {
                let catalog = HostCLIProviderCatalog(
                    owner: "usage",
                    commands: [
                        .init(
                            route: ["usage", "ls"], operation: "usage.cli",
                            summary: "Read original usage.")
                    ])
                var value = try JSONDecoder().decode(
                    HostCLIJSON.self, from: JSONEncoder().encode(catalog)
                ).object!
                value["coreOwner"] = .object([
                    "version": .integer(1), "owner": .string("usage"),
                    "agent": .object([
                        "jobs": .string("usage.agent.jobs"), "run": .string("usage.agent.run"),
                        "cancel": .string("usage.agent.cancel"),
                        "events": .string("usage.agent.events"),
                        "logs": .string("usage.agent.logs"),
                    ]),
                    "readiness": .object([
                        "inspect": .string("usage.lifecycle.inspect"),
                        "setup": .string("usage.lifecycle.setup"),
                    ]),
                ])
                return try HostCLIJSON.object(value).encoded()
            }
            let name = operation.split(separator: ".").last.map(String.init)!
            let payload = try JSONDecoder().decode(HostCLIJSON.self, from: request.payload)
            let data =
                try HostCLIJSON.object(["operation": .string(name), "payload": payload]).encoded()
                + Data([10])
            try input.fileHandleForWriting.write(contentsOf: data)
            var result = try CoreOwnerFrameReader.read(
                from: output.fileHandleForReading.fileDescriptor, operation: operation)
            if forgeValue && ["run", "cancel"].contains(name) {
                result = try HostCLIJSON.object([
                    "owner": .string("herdr"), "job": .string("usage.refresh"),
                    "accepted": .bool(true),
                ]).encoded()
            }
            if changeValue { disabledValue = true }
            return result
        }
    }

    func stop() {
        try? input.fileHandleForWriting.close()
        waitForExit(duration: .seconds(2))
        if process.isRunning {
            process.terminate()
            waitForExit(duration: .seconds(2))
        }
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            waitForExit(duration: .seconds(2))
        }
        guard !process.isRunning else {
            Issue.record("Owned fixture did not exit after bounded cleanup.")
            return
        }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
        try? FileManager.default.removeItem(at: root)
    }

    private func waitForExit(duration: Duration) {
        let deadline = ContinuousClock.now.advanced(by: duration)
        while process.isRunning && ContinuousClock.now < deadline { usleep(10000) }
    }
}

private struct CoreOwnerFrameFailure: Error, Equatable, CustomStringConvertible {
    enum Reason: String {
        case deadlineExceeded
        case endOfFile
        case emptyFrame
        case frameTooLarge
        case pollFailed
        case invalidDescriptor
        case readFailed
    }

    let reason: Reason
    let operation: String
    let byteCount: Int
    var systemError: Int32? = nil

    var description: String {
        "Owned fixture frame \(reason.rawValue): operation=\(operation), bytes=\(byteCount), errno=\(systemError.map(String.init) ?? "none")"
    }
}

private enum CoreOwnerFrameReader {
    static func read(
        from descriptor: Int32, operation: String, maximumBytes: Int = 1_048_576,
        duration: Duration = .seconds(5)
    ) throws -> Data {
        var result = Data()
        let deadline = ContinuousClock.now.advanced(by: duration)
        func failure(_ reason: CoreOwnerFrameFailure.Reason, systemError: Int32? = nil)
            -> CoreOwnerFrameFailure
        {
            CoreOwnerFrameFailure(
                reason: reason, operation: operation, byteCount: result.count,
                systemError: systemError)
        }
        while ContinuousClock.now < deadline {
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, 50)
            if ready < 0 {
                if errno == EINTR { continue }
                throw failure(.pollFailed, systemError: errno)
            }
            if ready == 0 { continue }
            if event.revents & Int16(POLLNVAL) != 0 { throw failure(.invalidDescriptor) }
            if event.revents & Int16(POLLERR) != 0 { throw failure(.pollFailed) }
            guard event.revents & Int16(POLLIN | POLLHUP) != 0 else { continue }
            var byte: UInt8 = 0
            let count = Darwin.read(descriptor, &byte, 1)
            if count < 0 {
                if errno == EINTR { continue }
                throw failure(.readFailed, systemError: errno)
            }
            guard count == 1 else { throw failure(.endOfFile) }
            if byte == 10 {
                guard !result.isEmpty else { throw failure(.emptyFrame) }
                return result
            }
            guard result.count < maximumBytes else { throw failure(.frameTooLarge) }
            result.append(byte)
        }
        throw failure(.deadlineExceeded)
    }
}

@Suite struct HostCoreOwnerFrameTests {
    @Test func fragmentedFrameWaitsForNewlineAndPreservesNextFrame() throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("{\"owner\": ".utf8))
        let writer = pipe.fileHandleForWriting
        let completion = DispatchGroup()
        completion.enter()
        DispatchQueue.global().async {
            defer { completion.leave() }
            usleep(20000)
            try? writer.write(contentsOf: Data("\"usage\"}\n{\"next\":true}\n".utf8))
        }
        let first = try CoreOwnerFrameReader.read(
            from: pipe.fileHandleForReading.fileDescriptor, operation: "fragmented")
        #expect(first == Data("{\"owner\": \"usage\"}".utf8))
        let second = try CoreOwnerFrameReader.read(
            from: pipe.fileHandleForReading.fileDescriptor, operation: "next")
        #expect(second == Data("{\"next\":true}".utf8))
        #expect(completion.wait(timeout: .now() + 1) == .success)
    }

    @Test func eofWithoutCompletedFrameReportsOperationAndBufferedBytes() throws {
        for partial in [Data(), Data("{\"owner\":".utf8)] {
            let pipe = Pipe()
            defer { try? pipe.fileHandleForReading.close() }
            try pipe.fileHandleForWriting.write(contentsOf: partial)
            try pipe.fileHandleForWriting.close()
            #expect(
                throws: CoreOwnerFrameFailure(
                    reason: .endOfFile, operation: "eof", byteCount: partial.count)
            ) {
                try CoreOwnerFrameReader.read(
                    from: pipe.fileHandleForReading.fileDescriptor, operation: "eof")
            }
        }
    }

    @Test func frameCapRejectsOversizeBeforeReturningPartialJSON() throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("12345\n".utf8))
        #expect(
            throws: CoreOwnerFrameFailure(
                reason: .frameTooLarge, operation: "oversize", byteCount: 4)
        ) {
            try CoreOwnerFrameReader.read(
                from: pipe.fileHandleForReading.fileDescriptor, operation: "oversize",
                maximumBytes: 4)
        }
    }

    @Test func deadlineWithPartialFrameReportsOperationAndBufferedBytes() throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("{}".utf8))
        #expect(
            throws: CoreOwnerFrameFailure(
                reason: .deadlineExceeded, operation: "deadline", byteCount: 2)
        ) {
            try CoreOwnerFrameReader.read(
                from: pipe.fileHandleForReading.fileDescriptor, operation: "deadline",
                duration: .milliseconds(100))
        }
    }

    @Test func invalidDescriptorAndEmptyFrameHaveNamedFailures() throws {
        #expect(
            throws: CoreOwnerFrameFailure(
                reason: .invalidDescriptor, operation: "invalid", byteCount: 0)
        ) {
            try CoreOwnerFrameReader.read(from: Int32.max, operation: "invalid")
        }
        let empty = Pipe()
        defer {
            try? empty.fileHandleForReading.close()
            try? empty.fileHandleForWriting.close()
        }
        try empty.fileHandleForWriting.write(contentsOf: Data([10]))
        #expect(
            throws: CoreOwnerFrameFailure(reason: .emptyFrame, operation: "empty", byteCount: 0)
        ) {
            try CoreOwnerFrameReader.read(
                from: empty.fileHandleForReading.fileDescriptor, operation: "empty")
        }
    }
}
