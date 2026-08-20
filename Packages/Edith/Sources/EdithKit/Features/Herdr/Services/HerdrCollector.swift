import Foundation

public enum HerdrCollector {
    public static let commandTimeout: TimeInterval = 12
    public static let pathPrefix =
        "$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

    public static func collect(_ scope: HerdrCollectScope = .all) async -> [HerdrHostSnapshot] {
        switch scope {
        case .all:
            async let local = collectLocal()
            let remotes = await collectRemotes(MachineRegistry.machines())
            return await [local] + remotes
        case .local:
            return [await collectLocal()]
        case let .machine(machine):
            return [await collectRemote(machine)]
        }
    }

    public static func executable() -> URL? {
        if let found = CLIToolEnvironment.executable(named: "herdr") { return found }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let extras = [
            home.appendingPathComponent(".local/bin/herdr"),
            home.appendingPathComponent(".cargo/bin/herdr"),
            URL(fileURLWithPath: "/opt/homebrew/bin/herdr"),
            URL(fileURLWithPath: "/usr/local/bin/herdr"),
        ]
        return extras.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static func collectLocal() async -> HerdrHostSnapshot {
        let machineID = HerdrHostSnapshot.localID
        let machineName = "This Mac"
        guard executable() != nil else {
            return .local(herdrPresent: false, error: "herdr is not on PATH")
        }
        let listed = await listAgents(
            runner: .local, machineID: machineID, machineName: machineName, machineIsLocal: true,
            sshTarget: nil)
        return .local(
            herdrPresent: listed.present, agents: listed.agents, error: listed.error)
    }

    public static func collectRemote(_ machine: Machine) async -> HerdrHostSnapshot {
        let connection = SSHConnection(machine: machine, controlSocketMode: .shared)
        do {
            try await connection.connect()
        } catch {
            return HerdrHostSnapshot(
                id: machine.id.uuidString, name: machine.name, isLocal: false,
                sshTarget: machine.sshTarget, herdrPresent: false, reachable: false,
                error: error.localizedDescription)
        }
        let listed = await listAgents(
            runner: .ssh(connection), machineID: machine.id.uuidString, machineName: machine.name,
            machineIsLocal: false, sshTarget: machine.sshTarget)
        return HerdrHostSnapshot(
            id: machine.id.uuidString, name: machine.name, isLocal: false,
            sshTarget: machine.sshTarget, herdrPresent: listed.present, reachable: true,
            agents: listed.agents, error: listed.error)
    }

    private static func collectRemotes(_ machines: [Machine]) async -> [HerdrHostSnapshot] {
        await withTaskGroup(of: HerdrHostSnapshot.self, returning: [HerdrHostSnapshot].self) {
            group in
            for machine in machines {
                group.addTask { await collectRemote(machine) }
            }
            var snapshots: [HerdrHostSnapshot] = []
            snapshots.reserveCapacity(machines.count)
            for await snapshot in group { snapshots.append(snapshot) }
            let order = Dictionary(
                uniqueKeysWithValues: machines.enumerated().map {
                    ($0.element.id.uuidString, $0.offset)
                })
            return snapshots.sorted { lhs, rhs in
                (order[lhs.id] ?? .max) < (order[rhs.id] ?? .max)
            }
        }
    }

    private enum Runner {
        case local
        case ssh(SSHConnection)
    }

    private struct Listing {
        var present: Bool
        var agents: [HerdrAgent]
        var error: String?
    }

    private static func listAgents(
        runner: Runner, machineID: String, machineName: String, machineIsLocal: Bool,
        sshTarget: String?
    ) async -> Listing {
        let sessionsResult = await run(runner, herdr: "session list --json")
        if isMissing(sessionsResult) {
            return Listing(present: false, agents: [], error: "herdr is not installed")
        }
        let sessions = HerdrListParser.sessions(from: sessionsResult.stdout)
        let names = sessions.isEmpty ? ["default"] : sessions
        var agents: [HerdrAgent] = []
        var lastError: String?
        for session in names {
            let listed = await agentsInSession(
                runner: runner, session: session, machineID: machineID, machineName: machineName,
                machineIsLocal: machineIsLocal, sshTarget: sshTarget)
            if !listed.present {
                return Listing(present: false, agents: [], error: listed.error)
            }
            if listed.agents.isEmpty { lastError = listed.error }
            agents.append(contentsOf: listed.agents)
        }
        return Listing(
            present: true, agents: agents,
            error: agents.isEmpty
                ? lastError ?? jsonOrProcessError(sessionsResult) : nil)
    }

    private static func agentsInSession(
        runner: Runner, session: String, machineID: String, machineName: String,
        machineIsLocal: Bool, sshTarget: String?
    ) async -> Listing {
        let quoted = ShellQuote.quote(session)
        let snapshot = await run(runner, herdr: "--session \(quoted) api snapshot")
        if isMissing(snapshot) {
            return Listing(present: false, agents: [], error: "herdr is not installed")
        }
        if HerdrListParser.hasSnapshot(snapshot.stdout) {
            let agents = HerdrListParser.agents(
                fromSnapshot: snapshot.stdout, session: session, machineID: machineID,
                machineName: machineName, machineIsLocal: machineIsLocal, sshTarget: sshTarget)
            return Listing(
                present: true, agents: agents,
                error: agents.isEmpty ? jsonOrProcessError(snapshot) : nil)
        }
        let result = await run(runner, herdr: "--session \(quoted) agent list")
        if isMissing(result) {
            return Listing(present: false, agents: [], error: "herdr is not installed")
        }
        let agents = HerdrListParser.agents(
            from: result.stdout, session: session, machineID: machineID,
            machineName: machineName, machineIsLocal: machineIsLocal, sshTarget: sshTarget)
        return Listing(
            present: true, agents: agents,
            error: agents.isEmpty ? jsonOrProcessError(result) : nil)
    }

    private struct CommandResult {
        var status: Int32
        var stdout: String
        var stderr: String
        var ok: Bool { status == 0 }
    }

    private static func run(_ runner: Runner, herdr arguments: String) async -> CommandResult {
        let command = "export PATH=\"\(pathPrefix)\"; herdr \(arguments)"
        switch runner {
        case .local:
            return await runLocal(command)
        case let .ssh(connection):
            do {
                let result = try await connection.run(command, timeout: commandTimeout)
                return CommandResult(
                    status: result.status, stdout: result.stdoutText, stderr: result.stderrText)
            } catch {
                return CommandResult(status: 1, stdout: "", stderr: error.localizedDescription)
            }
        }
    }

    private static func runLocal(_ command: String) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            process.environment = CLIToolEnvironment.sanitized()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return CommandResult(status: 1, stdout: "", stderr: error.localizedDescription)
            }
            let status = await waitForExit(process, timeout: commandTimeout)
            let stdout = String(
                decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let stderr = String(
                decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return CommandResult(status: status, stdout: stdout, stderr: stderr)
        }.value
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) async -> Int32 {
        await withCheckedContinuation { continuation in
            let gate = ResumeOnce()
            let resume: @Sendable (Int32) -> Void = { status in
                guard gate.claim() else { return }
                continuation.resume(returning: status)
            }
            process.terminationHandler = { resume($0.terminationStatus) }
            if !process.isRunning {
                resume(process.terminationStatus)
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    process.terminate()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        resume(process.terminationStatus)
                    }
                }
            }
        }
    }

    private static func jsonOrProcessError(_ result: CommandResult) -> String? {
        HerdrListParser.errorMessage(in: result.stdout)
            ?? HerdrListParser.errorMessage(in: result.stderr)
            ?? message(from: result)
    }

    private static func isMissing(_ result: CommandResult) -> Bool {
        if result.status == 127 { return true }
        let text = (result.stdout + "\n" + result.stderr).lowercased()
        return text.contains("command not found") || text.contains("no such file")
            || text.contains("not found: herdr")
    }

    private static func message(from result: CommandResult) -> String? {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.ok, !stdout.isEmpty { return stdout }
        if !result.ok { return "herdr exited \(result.status)" }
        return nil
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}
