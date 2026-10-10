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
            var result = Data()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline {
                var event = pollfd(
                    fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN),
                    revents: 0)
                if poll(&event, 1, 50) == 0 { continue }
                guard let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty
                else { throw HostCLIError.unavailable }
                if byte == Data([10]) { break }
                result += byte
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
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { usleep(10000) }
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? output.fileHandleForReading.close()
        try? FileManager.default.removeItem(at: root)
    }
}
