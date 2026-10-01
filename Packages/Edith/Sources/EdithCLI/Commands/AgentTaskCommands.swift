import ArgumentParser
import EdithKit
import Foundation

struct AgentTasksCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tasks", abstract: "Inspect and control background tasks.",
        discussion: """
            List, inspect, cancel, or exec tasks in the background agent.
            Reads the agent's task store. cancel and exec change the queue. ls and inspect do not change anything.

            ed agent tasks ls
            ed agent tasks inspect <id>
            """,
        subcommands: [
            AgentTasksListCommand.self, AgentTasksInspectCommand.self,
            AgentTasksCancelCommand.self, AgentTasksExecCommand.self,
        ], defaultSubcommand: AgentTasksListCommand.self)
}

struct AgentTasksListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List active and completed background tasks.",
        discussion: """
            List tasks with id, state, and title.
            Reads the task store. Does not change tasks.

            ed agent tasks ls
            ed agent tasks ls --json
            """)
    @Flag(name: .long, help: "Emit the task list as JSON.") var json = false

    func run() async throws {
        try await execute {
            let tasks = try await AgentTaskClient().snapshots()
            if json {
                CLIOut.out(String(decoding: try AgentPayload.encode(tasks), as: UTF8.self))
            } else {
                CLIOut.out(
                    TextTable.render(
                        headers: ["ID", "STATE", "TITLE"],
                        rows: tasks.map { [$0.id.uuidString, $0.state.rawValue, $0.title] }))
            }
        }
    }
}

struct AgentTasksInspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect", abstract: "Read a task's progress and retained result.",
        discussion: """
            Read one task's progress, output, and failure.
            Reads that task. Does not change it. The id is a UUID from ed agent tasks ls.

            ed agent tasks inspect <id>
            ed agent tasks inspect <id> --json
            """)
    @Argument(help: "Task UUID from ed agent tasks ls.") var id: String
    @Flag(name: .long, help: "Emit the task as JSON.") var json = false

    func run() async throws {
        try await execute {
            guard let identifier = UUID(uuidString: id) else {
                throw ValidationError("Enter a task UUID from ed agent tasks ls.")
            }
            let status = try await AgentTaskClient().status(identifier)
            if json {
                CLIOut.out(String(decoding: try AgentPayload.encode(status), as: UTF8.self))
            } else {
                CLIOut.out("\(status.snapshot.title): \(status.snapshot.state.rawValue)")
                for output in status.output { CLIOut.out(output.text) }
                if let failure = status.snapshot.failure { CLIOut.out(failure) }
            }
        }
    }
}

struct AgentTasksCancelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cancel", abstract: "Cancel a queued or running background task.",
        discussion: """
            Cancel one queued or running task.
            Reads the task id. Changes that task by requesting cancellation.

            ed agent tasks cancel <id>
            ed agent tasks cancel <id> --json
            """)
    @Argument(help: "Task UUID from ed agent tasks ls.") var id: String
    @Flag(name: .long, help: "Emit the task as JSON.") var json = false

    func run() async throws {
        try await execute {
            guard let identifier = UUID(uuidString: id) else {
                throw ValidationError("Enter a task UUID from ed agent tasks ls.")
            }
            let snapshot = try await AgentTaskClient().cancel(identifier)
            if json {
                CLIOut.out(String(decoding: try AgentPayload.encode(snapshot), as: UTF8.self))
            } else {
                CLIOut.out("\(snapshot.id): \(snapshot.state.rawValue)")
            }
        }
    }
}

struct AgentTasksExecCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exec", abstract: "Execute a command in the daemon's bounded task queue.",
        discussion: """
            Run an absolute executable inside the daemon's task queue.
            Reads the command after --. Changes the queue by submitting it. --detach returns the task id immediately. Output is capped.

            ed agent tasks exec -- /usr/bin/true
            ed agent tasks exec --json --detach -- /usr/bin/true
            """)
    @Flag(name: .long, help: "Emit the task result as JSON.") var json = false
    @Flag(name: .long, help: "Return the task ID immediately.") var detach = false
    @Option(name: .long, help: "Maximum running time in seconds.") var timeout: Double = 300
    @Argument(parsing: .postTerminator, help: "Absolute executable and arguments, after --.")
    var command: [String]

    mutating func validate() throws {
        guard let path = command.first, path.hasPrefix("/") else {
            throw ValidationError("Provide an absolute executable path after --.")
        }
        guard timeout.isFinite, timeout > 0 else {
            throw ValidationError("Timeout must be a positive number.")
        }
    }

    func run() async throws {
        try await execute {
            let client = AgentTaskClient()
            let request = CLICommandRequest(
                executableURL: URL(fileURLWithPath: command[0]),
                arguments: Array(command.dropFirst()), environment: CLIToolEnvironment.sanitized(),
                currentDirectoryURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                timeout: timeout, maximumOutputBytes: 4 << 20, terminatesProcessGroup: true)
            if detach {
                let snapshot = try await client.submit(
                    AgentTaskSubmission(
                        operation: AgentTaskOperation.command,
                        title: "Running \(request.executableURL.lastPathComponent)",
                        payload: AgentPayload.encode(request)))
                if json {
                    CLIOut.out(String(decoding: try AgentPayload.encode(snapshot), as: UTF8.self))
                } else {
                    CLIOut.out(snapshot.id.uuidString)
                }
            } else {
                let result = try await client.runCommand(
                    request, onStandardOutputLine: { _ in }, onStandardErrorLine: { _ in })
                if json {
                    CLIOut.out(String(decoding: try AgentPayload.encode(result), as: UTF8.self))
                } else {
                    FileHandle.standardOutput.write(result.standardOutputData)
                    FileHandle.standardError.write(result.standardErrorData)
                }
                if result.terminationStatus != 0 {
                    throw ExitCode(result.terminationStatus)
                }
            }
        }
    }
}
