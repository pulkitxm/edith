import Darwin
import Foundation
import EdithExtensionSupport
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

    @Test(arguments: 0..<8)
    func liveChildWithoutProtocolRequestsRetiresAndJoins(_ iteration: Int) throws {
        let owner = try CoreOwnerFixture()
        owner.stop()
        #expect(!FileManager.default.fileExists(atPath: owner.root.path))
    }

    @Test func missingLiveOriginalOwnerDiagnosticsReturnActionableUnavailability() async throws {
        let identity = try #require(ExtensionProcessIdentity.current)
        #expect(identity.isAlive)
        let owner = MissingCoreOwnerFixture(pid: identity.pid)
        let hooks = HostCoreOwnerHooks(invoke: { try owner.invoke($0) })
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
        #expect(identity.isAlive)
        #expect(
            owner.calls
                == Array(repeating: ["ls", "usage.cli.catalog", "ls"], count: 3)
                .flatMap { $0 })
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

private final class MissingCoreOwnerFixture: @unchecked Sendable {
    private let pid: Int32
    private let lock = NSLock()
    private var callsValue: [String] = []
    var calls: [String] { lock.withLock { callsValue } }

    init(pid: Int32) { self.pid = pid }

    func invoke(_ request: HostCLIRequest) throws -> Data {
        try lock.withLock {
            if request.action == .ls {
                callsValue.append("ls")
                return try HostCLIJSON.array([
                    .object([
                        "id": .string("usage"), "installed": .bool(true), "compatible": .bool(true),
                        "enabled": .bool(true), "running": .bool(true), "version": .string("1"),
                        "disablePending": .bool(false), "removalPending": .bool(false),
                        "processIdentifier": .integer(Int64(pid)),
                    ])
                ]).encoded()
            }
            guard request.action == .invoke, request.id == "usage",
                request.operation == "usage.cli.catalog"
            else { throw HostCLIError.rejected("Unexpected original owner protocol invocation.") }
            callsValue.append("usage.cli.catalog")
            return try JSONEncoder().encode(
                HostCLIProviderCatalog(
                    owner: "usage",
                    commands: [
                        .init(
                            route: ["usage", "ls"], operation: "usage.cli",
                            summary: "Read original usage.")
                    ]))
        }
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
    private var requestCount: UInt64 = 0
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
        let temporaryPath = try #require(ProcessInfo.processInfo.environment["TMPDIR"])
        try #require(temporaryPath.hasPrefix("/"))
        let temporary = URL(
            fileURLWithPath: temporaryPath, isDirectory: true
        ).standardizedFileURL.resolvingSymlinksInPath()
        root = temporary.appendingPathComponent(
            "core-owner-" + UUID().uuidString, isDirectory: true)
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
            requestCount += 1
            var result: Data
            do {
                result = try CoreOwnerFrameReader.read(
                    from: output.fileHandleForReading.fileDescriptor, operation: operation)
            } catch let failure as CoreOwnerFrameFailure {
                let diagnostic = CoreOwnerFrameDiagnostic(
                    failure: failure, requestCount: requestCount,
                    processRunning: process.isRunning,
                    trace: .capture(root.appendingPathComponent("trace")))
                if let data = diagnostic.encoded(), let line = String(data: data, encoding: .utf8) {
                    print(line)
                }
                throw failure
            }
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
        try? output.fileHandleForReading.close()
        try? FileManager.default.removeItem(at: root)
    }

    private func waitForExit(duration: Duration) {
        let deadline = ContinuousClock.now.advanced(by: duration)
        while process.isRunning && ContinuousClock.now < deadline { usleep(10000) }
    }
}

private struct CoreOwnerTraceMetadata: Encodable {
    let present: Bool
    let regular: Bool
    let singleLink: Bool
    let owned: Bool
    let sizeUnder4096: Bool

    static func capture(_ url: URL) -> Self {
        var info = stat()
        let present = url.path.withCString { lstat($0, &info) == 0 }
        return Self(
            present: present,
            regular: present && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            singleLink: present && info.st_nlink == 1, owned: present && info.st_uid == getuid(),
            sizeUnder4096: present && info.st_size >= 0 && info.st_size < 4096)
    }
}

private struct CoreOwnerFrameDiagnostic: Encodable {
    let reason: String
    let operation: String
    let frameBytes: Int
    let requestCount: UInt64
    let processRunning: Bool
    let trace: CoreOwnerTraceMetadata

    init(
        failure: CoreOwnerFrameFailure, requestCount: UInt64, processRunning: Bool,
        trace: CoreOwnerTraceMetadata
    ) {
        reason = failure.reason.rawValue
        operation =
            [
                "usage.agent.jobs", "usage.agent.run", "usage.agent.cancel", "usage.agent.events",
                "usage.agent.logs", "usage.lifecycle.inspect", "usage.lifecycle.setup",
            ].contains(failure.operation) ? failure.operation : "unknown"
        frameBytes = failure.byteCount
        self.requestCount = requestCount
        self.processRunning = processRunning
        self.trace = trace
    }

    func encoded() -> Data? {
        guard frameBytes >= 0, frameBytes <= 1_048_576,
            let data = try? JSONEncoder().encode(self), data.count <= 1024
        else { return nil }
        return data
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

@Suite struct HostCoreOwnerDiagnosticTests {
    @Test func repeatedJobsKeepTheActualRequestCounterWithoutPrivateFields() throws {
        for count: UInt64 in [1, 3, 5] {
            let diagnostic = CoreOwnerFrameDiagnostic(
                failure: .init(
                    reason: .deadlineExceeded, operation: "usage.agent.jobs", byteCount: 0),
                requestCount: count, processRunning: true,
                trace: .init(
                    present: true, regular: true, singleLink: true, owned: true, sizeUnder4096: true
                ))
            let data = try #require(diagnostic.encoded())
            let value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(
                Set(value.keys) == [
                    "reason", "operation", "frameBytes", "requestCount", "processRunning", "trace",
                ])
            #expect(value["reason"] as? String == "deadlineExceeded")
            #expect(value["operation"] as? String == "usage.agent.jobs")
            #expect((value["requestCount"] as? NSNumber)?.uint64Value == count)
            #expect((value["frameBytes"] as? NSNumber)?.intValue == 0)
            #expect((value["processRunning"] as? NSNumber)?.boolValue == true)
            #expect(data.count <= 1024)
        }
    }

    @Test func everyFrameReasonIsBoundedAndUnknownOperationsAreRedacted() throws {
        let reasons: [CoreOwnerFrameFailure.Reason] = [
            .deadlineExceeded, .endOfFile, .emptyFrame, .frameTooLarge, .pollFailed,
            .invalidDescriptor, .readFailed,
        ]
        for reason in reasons {
            let diagnostic = CoreOwnerFrameDiagnostic(
                failure: .init(
                    reason: reason, operation: "/private/synthetic-operation", byteCount: 1_048_576),
                requestCount: .max, processRunning: false,
                trace: .init(
                    present: false, regular: false, singleLink: false, owned: false,
                    sizeUnder4096: false))
            let data = try #require(diagnostic.encoded())
            let value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(value["reason"] as? String == reason.rawValue)
            #expect(value["operation"] as? String == "unknown")
            #expect(!String(decoding: data, as: UTF8.self).contains("/private/"))
            #expect(data.count <= 1024)
        }
        for bytes in [-1, 1_048_577] {
            #expect(
                CoreOwnerFrameDiagnostic(
                    failure: .init(
                        reason: .frameTooLarge, operation: "usage.agent.logs", byteCount: bytes),
                    requestCount: 1, processRunning: true,
                    trace: .init(
                        present: false, regular: false, singleLink: false, owned: false,
                        sizeUnder4096: false)
                ).encoded() == nil)
        }
    }

    @Test func traceMetadataChecksActualOwnedFilesWithoutReadingTheirContents() throws {
        let temporaryPath = try #require(ProcessInfo.processInfo.environment["TMPDIR"])
        try #require(temporaryPath.hasPrefix("/"))
        let temporary = URL(
            fileURLWithPath: temporaryPath, isDirectory: true
        ).standardizedFileURL.resolvingSymlinksInPath()
        let root = temporary.appendingPathComponent(
            "core-owner-diagnostic-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try #require(root.resolvingSymlinksInPath() == root)
        try #require(root.deletingLastPathComponent() == temporary)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        try #require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let trace = root.appendingPathComponent("trace")
        let missing = CoreOwnerTraceMetadata.capture(trace)
        #expect(
            !missing.present && !missing.regular && !missing.singleLink && !missing.owned
                && !missing.sizeUnder4096)
        try Data("Synthetic private trace".utf8).write(to: trace)
        let regular = CoreOwnerTraceMetadata.capture(trace)
        #expect(
            regular.present && regular.regular && regular.singleLink && regular.owned
                && regular.sizeUnder4096)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: trace)
        #expect(!CoreOwnerTraceMetadata.capture(link).regular)
        try FileManager.default.linkItem(at: trace, to: root.appendingPathComponent("hardlink"))
        #expect(!CoreOwnerTraceMetadata.capture(trace).singleLink)
        try Data(repeating: 0, count: 4096).write(to: trace)
        #expect(!CoreOwnerTraceMetadata.capture(trace).sizeUnder4096)
        let directory = CoreOwnerTraceMetadata.capture(root)
        #expect(directory.present && !directory.regular && directory.owned)
        let data = try JSONEncoder().encode(regular)
        let value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(value.keys) == ["present", "regular", "singleLink", "owned", "sizeUnder4096"])
        #expect(!String(decoding: data, as: UTF8.self).contains("Synthetic private trace"))
        #expect(!String(decoding: data, as: UTF8.self).contains(root.path))
    }
}
