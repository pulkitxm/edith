import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing
@testable import QuinjetUI

@MainActor @Suite(.serialized) struct QuinjetCLIExecutionTests {
    @Test func ownedStreamsExecuteOriginalCommandsWithRetainedOwnerContext() async throws {
        defer { QuinjetWorkOwnership.enable() }
        let worker = QuinjetWorker(
            client: .init(execute: { _ in Data("[]".utf8) }), automaticActions: false)
        let request = try ExtensionCLIRequest(
            arguments: ["new", "--json"],
            standardInput: Data("synthetic input".utf8), workingDirectory: "/private/tmp",
            interactive: false)
        let data = try JSONEncoder().encode(
            ExtensionCLIStreamStart(
                owner: "quinjet", session: UUID(), request: request, deadline: 5))
        let handle = try JSONDecoder().decode(
            ExtensionCLIStreamHandle.self,
            from: await worker.execute("quinjet.cli.start", payload: data))
        var cursor: UInt64 = 0
        var output = Data()
        var errors = Data()
        var exit: Int32?
        for _ in 0..<100 {
            let frame = try JSONDecoder().decode(
                ExtensionCLIStreamFrame.self,
                from: await worker.execute(
                    "quinjet.cli.read",
                    payload: JSONEncoder().encode(
                        ExtensionCLIStreamRead(handle: handle, sequence: cursor))))
            try frame.validate()
            cursor = frame.nextSequence
            for chunk in frame.chunks {
                if chunk.channel == .stdout {
                    output.append(chunk.data)
                } else {
                    errors.append(chunk.data)
                }
            }
            if let code = frame.exitCode { exit = code; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(exit == 0 && errors.isEmpty)
        #expect(worker.model.tabs.count == 2)
        #expect(String(decoding: output, as: UTF8.self).contains(worker.model.selected.uuidString))
        let wrong = ExtensionCLIStreamHandle(
            owner: "quinjet", session: handle.session, token: UUID())
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute("quinjet.cli.end", payload: JSONEncoder().encode(wrong))
        }
        _ = try await worker.execute("quinjet.cli.end", payload: JSONEncoder().encode(handle))
        await worker.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute(
                "quinjet.cli.read",
                payload: JSONEncoder().encode(
                    ExtensionCLIStreamRead(handle: handle, sequence: cursor)))
        }
        #expect(QuinjetCLIEnvironment.context == nil && ExtensionCLIContext.request == nil)
    }

    @Test func originalForegroundLaunchConsumesRequestInputAndResolvesCallerDirectory() async throws
    {
        defer { QuinjetWorkOwnership.enable() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("synthetic project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fixture-tool")
        try Data("#!/bin/sh\n/bin/cat\nprintf 'fixture-error' >&2\nexit 17\n".utf8).write(
            to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let previous = CLIEnvironment.executableNamed
        CLIEnvironment.executableNamed = { _ in executable }
        defer { CLIEnvironment.executableNamed = previous }
        let tree = QuinjetWorktree(
            path: project.path, head: "1234567", branch: "fixture",
            current: true, bare: false, detached: false, locked: nil, prunable: nil)
        let client = QuinjetClient(execute: { arguments in
            #expect(arguments == ["-C", project.path, "worktree", "list", "--json"])
            #expect(ExtensionCLIContext.request?.workingDirectory == root.path)
            #expect(ExtensionCLIContext.request?.interactive == false)
            return try JSONEncoder().encode([tree])
        })
        let worker = QuinjetWorker(client: client, automaticActions: false)
        let reply = try await QuinjetCLIExecution.run(
            .init(
                arguments: ["launch", "synthetic project", "--json"],
                standardInput: Data("fixture-input ☃".utf8), workingDirectory: root.path),
            worker: worker)
        #expect(reply.exitCode == 17 && reply.stdout.isEmpty)
        #expect(reply.stderr == "fixture-input ☃fixture-error")
        let foreground = try await QuinjetCLIExecution.run(
            .init(
                arguments: ["launch", "synthetic project"],
                standardInput: Data("fixture-input ☃".utf8),
                workingDirectory: root.path, interactive: false), worker: worker)
        #expect(foreground.exitCode == 17 && foreground.stdout == "fixture-input ☃")
        #expect(foreground.stderr == "fixture-error")
        #expect(ExtensionCLIContext.request == nil && QuinjetCLIEnvironment.context == nil)
        await worker.shutdown()
    }

    @Test func liveCatalogPublishesOriginalLeafRoutesAndWithdrawsWithOwner() async throws {
        defer { QuinjetWorkOwnership.enable() }
        let worker = QuinjetWorker(
            client: .init(execute: { _ in Data("[]".utf8) }), automaticActions: false)
        let data = try await worker.execute("quinjet.cli.catalog", payload: Data("{}".utf8))
        let value = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(value["owner"] as? String == "quinjet" && value["version"] as? Int == 1)
        let commands = try #require(value["commands"] as? [[String: Any]])
        let routes = commands.compactMap { $0["route"] as? [String] }
        #expect(routes.contains(["quinjet", "launch"]))
        #expect(Set(routes.map { $0.joined(separator: " ") }).count == routes.count)
        #expect(
            commands.allSatisfy {
                $0["operation"] as? String == "quinjet.cli"
                    && $0["streamOperation"] as? String == "quinjet.cli"
            })
        await worker.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute("quinjet.cli.catalog", payload: Data("{}".utf8))
        }
    }

    @Test func originalMachineSelectorsAcceptSavedIDsNamesTargetsAndUnambiguousPrefixes() throws {
        let first = Machine(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            name: "Build one", host: "fixture-one")
        let second = Machine(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            name: "Build two", host: "fixture-two")
        let machines = [first, second]
        for query in [first.id.uuidString.lowercased(), "1000", "build ONE", "fixture-one"] {
            #expect(try MachineResolver.machine(query, in: machines) == first)
        }
        for query in ["build", "fixture", "missing", ""] {
            #expect(throws: CLIFailure.self) { try MachineResolver.machine(query, in: machines) }
        }
    }

    @Test func originalSessionCommandsMutateOwningModelAndPreserveStreams() async throws {
        defer { QuinjetWorkOwnership.enable() }
        let worker = QuinjetWorker(
            client: .init(execute: { _ in Data("[]".utf8) }), automaticActions: false)
        let initial = try await QuinjetCLIExecution.run(
            .init(arguments: ["sessions", "--json"]), worker: worker)
        #expect(initial.exitCode == 0 && initial.stderr.isEmpty && worker.model.tabs.count == 1)
        let created = try await QuinjetCLIExecution.run(
            .init(arguments: ["new", "--json"]), worker: worker)
        #expect(created.exitCode == 0 && worker.model.tabs.count == 2)
        let focused = try await QuinjetCLIExecution.run(
            .init(arguments: ["focus", "1", "--json"]), worker: worker)
        #expect(focused.exitCode == 0 && worker.model.selected == worker.model.tabs[0].id)
        let missing = try await QuinjetCLIExecution.run(
            .init(arguments: ["focus", "missing", "--json"]), worker: worker)
        #expect(
            missing.exitCode == 3 && missing.stdout.isEmpty
                && missing.stderr.contains("No native Quinjet session"))
        let closed = try await QuinjetCLIExecution.run(
            .init(arguments: ["close", "2", "--yes", "--json"]), worker: worker)
        #expect(closed.exitCode == 0 && worker.model.tabs.count == 1)
        await worker.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            try await QuinjetCLIExecution.run(.init(arguments: ["sessions"]), worker: worker)
        }
    }

    @Test func originalProjectAndOpenCommandsUseActualSelectionAndLaunchBuilder() async throws {
        defer { QuinjetWorkOwnership.enable() }
        let previous = CLIEnvironment.executableNamed
        CLIEnvironment.executableNamed = { _ in URL(fileURLWithPath: "/tmp/synthetic-quinjet") }
        defer { CLIEnvironment.executableNamed = previous }
        let tree = QuinjetWorktree(
            path: "/tmp/mock project", head: "1234567", branch: "feature",
            current: true, bare: false, detached: false, locked: nil, prunable: nil)
        let client = QuinjetClient(execute: { arguments in
            if arguments == ["project", "list", "--json"] {
                return try JSONEncoder().encode([
                    QuinjetProject(
                        name: "Synthetic", commonDir: "/tmp/mock project/.git", worktrees: [tree])
                ])
            }
            #expect(arguments == ["-C", "/tmp/mock project", "worktree", "list", "--json"])
            return try JSONEncoder().encode([tree])
        })
        let worker = QuinjetWorker(client: client, automaticActions: false)
        let projects = try await QuinjetCLIExecution.run(
            .init(arguments: ["projects", "--json"]), worker: worker)
        #expect(
            projects.exitCode == 0 && projects.stdout.contains("Synthetic")
                && projects.stderr.isEmpty)
        let plan = try await QuinjetCLIExecution.run(
            .init(arguments: ["open", "/tmp/mock project", "--json"]), worker: worker)
        #expect(
            plan.exitCode == 0 && plan.stderr.isEmpty
                && plan.stdout.contains("/tmp/synthetic-quinjet"))
        #expect(plan.stdout.contains("feature") && plan.stdout.contains("--appearance"))
        let conflict = try await QuinjetCLIExecution.run(
            .init(arguments: ["open", "/tmp/mock project", "--cmux", "--embedded"]), worker: worker)
        #expect(
            conflict.exitCode == 2 && conflict.stdout.isEmpty
                && conflict.stderr.contains("cannot be used together"))
        await worker.shutdown()
    }
}
