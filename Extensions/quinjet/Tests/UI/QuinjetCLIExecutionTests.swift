import EdithExtensionSupport
import Foundation
import Testing
@testable import QuinjetUI

@MainActor @Suite(.serialized) struct QuinjetCLIExecutionTests {
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
