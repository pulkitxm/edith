import EdithExtensionAccounts
import EdithExtensionSupport
import Foundation

public enum HerdrPaneSplitCommand {
    public static func arguments(
        pane: String, cwd: String?, environment: [String: String] = [:]
    ) -> [String] {
        var arguments = ["pane", "split", pane, "--direction", "right", "--no-focus"]
        if let cwd, !cwd.isEmpty { arguments += ["--cwd", cwd] }
        return arguments
            + environment.sorted { $0.key < $1.key }.flatMap { ["--env", $0.key + "=" + $0.value] }
    }
}

public enum HerdrAgentRestartError: LocalizedError, Equatable {
    case unsupported(String)
    case stillRunning
    case paneGone
    case sessionUnknown(String)
    case transcriptMissing(String)
    case accountNeedsDefaultSession

    public var errorDescription: String? {
        switch self {
        case .unsupported(let kind): "\(kind) cannot be restarted from Edith."
        case .stillRunning: "The agent did not quit. It is still running in its terminal."
        case .paneGone: "The agent's terminal is gone."
        case .sessionUnknown(let kind):
            "The agent quit, but \(kind) did not report a session to resume. Its last output is still in the terminal."
        case .transcriptMissing(let id):
            "The agent quit, but the transcript for session \(id) could not be found."
        case .accountNeedsDefaultSession:
            "Claude accounts can only start in the default Herdr session."
        }
    }
}

public struct HerdrAgentQuitSteps: Sendable {
    public var state: @Sendable () async throws -> HerdrPaneState
    public var press: @Sendable (String) async throws -> Void
    public var read: @Sendable () async throws -> String

    public init(
        state: @escaping @Sendable () async throws -> HerdrPaneState,
        press: @escaping @Sendable (String) async throws -> Void,
        read: @escaping @Sendable () async throws -> String
    ) {
        self.state = state
        self.press = press
        self.read = read
    }
}

public struct HerdrAgentRestartSteps: Sendable {
    public var quit: @Sendable (HerdrAgent) async throws -> String
    public var locateClaudeTranscript:
        @Sendable (_ script: String, _ machine: Machine?) async throws -> String?
    public var createPane:
        @Sendable (_ agent: HerdrAgent, _ machine: Machine?, _ environment: [String: String])
            async throws -> HerdrCreatedPane
    public var closePane: @Sendable (_ agent: HerdrAgent, _ machine: Machine?) async throws -> Void
    public var start:
        @Sendable (
            _ kind: String, _ leading: [String], _ pane: String, _ session: String,
            _ machine: Machine?
        ) async throws -> Void

    public init(
        quit: @escaping @Sendable (HerdrAgent) async throws -> String,
        locateClaudeTranscript:
            @escaping @Sendable (String, Machine?) async throws -> String?,
        createPane:
            @escaping @Sendable (HerdrAgent, Machine?, [String: String]) async throws ->
            HerdrCreatedPane,
        closePane: @escaping @Sendable (HerdrAgent, Machine?) async throws -> Void,
        start:
            @escaping @Sendable (String, [String], String, String, Machine?) async throws -> Void
    ) {
        self.quit = quit
        self.locateClaudeTranscript = locateClaudeTranscript
        self.createPane = createPane
        self.closePane = closePane
        self.start = start
    }

    public static let live = HerdrAgentRestartSteps(
        quit: { try await HerdrAgentRestartExecution.quit($0) },
        locateClaudeTranscript: { try await HerdrAgentRestartExecution.runScript($0, on: $1) },
        createPane: { agent, machine, environment in
            let output = try await HerdrCommand.run(
                HerdrSessionCommand.scoped(
                    HerdrPaneSplitCommand.arguments(
                        pane: agent.pane, cwd: agent.cwd, environment: environment),
                    session: agent.session), timeout: 15, on: machine)
            guard let created = HerdrListParser.splitPane(from: output) else {
                throw HerdrCommandError.malformedResponse
            }
            return created
        },
        closePane: { agent, machine in
            try await HerdrPaneOperations.close(
                session: agent.session, pane: agent.pane, on: machine)
        },
        start: { kind, leading, pane, session, machine in
            try await HerdrLaunchOperations.launchAgent(
                kind: kind,
                name: HerdrLaunchSettings.defaultHerdrSlug(for: kind) ?? kind.lowercased(),
                pane: pane, options: HerdrLaunchSettings.options(for: kind),
                leadingArguments: leading, session: session, on: machine)
        })
}

public enum HerdrAgentRestartExecution {
    static let exitLines = 400
    static let codexExitChoice = "3"
    static let codexExitMenu = "Stop the current task and exit Codex"
    private static let attempts = 3

    public static func quit(_ agent: HerdrAgent) async throws -> String {
        let machine = try machine(for: agent)
        return try await quit(
            kind: agent.kind,
            steps: HerdrAgentQuitSteps(
                state: {
                    try await HerdrPaneOperations.state(
                        session: agent.session, pane: agent.pane, on: machine)
                },
                press: { key in
                    _ = try await HerdrCommand.run(
                        HerdrSessionCommand.scoped(
                            ["pane", "send-keys", agent.pane, key], session: agent.session),
                        timeout: 10, on: machine)
                },
                read: {
                    try await HerdrCommand.run(
                        HerdrSessionCommand.scoped(
                            [
                                "pane", "read", agent.pane, "--source", "recent-unwrapped",
                                "--lines", String(exitLines),
                            ], session: agent.session), timeout: 10, on: machine)
                }))
    }

    public static func quit(
        kind: String, steps: HerdrAgentQuitSteps, patience: Duration = .seconds(3),
        pressGap: Duration = HerdrAgentCloseExecution.pressGap,
        interval: Duration = .milliseconds(250)
    ) async throws -> String {
        let isCodex = HerdrKind.displayName(for: kind) == "Codex"
        func exited() async -> Bool {
            await HerdrPaneOperations.waitForShell(
                timeout: patience, interval: interval, state: steps.state)
        }
        for _ in 0..<attempts {
            switch try? await steps.state() {
            case .missing?: throw HerdrAgentRestartError.paneGone
            case .live(let process?)? where !process.running: return try await steps.read()
            default: break
            }
            try await steps.press("ctrl+c")
            if !isCodex {
                try await Task.sleep(for: pressGap)
                try await steps.press("ctrl+c")
            }
            if await exited() { return try await steps.read() }
            if isCodex, let screen = try? await steps.read(), screen.contains(codexExitMenu) {
                try await steps.press(codexExitChoice)
                if await exited() { return try await steps.read() }
            }
        }
        throw HerdrAgentRestartError.stillRunning
    }

    static func runScript(_ script: String, on machine: Machine?) async throws -> String? {
        if let machine {
            let connection = SSHConnection(machine: machine, controlSocketMode: .shared)
            try await connection.connect()
            guard await connection.remotePlatform != .windows else { return nil }
            let result = try await connection.run(script, timeout: 30)
            if result.status == ClaudeTranscriptCommand.notFoundStatus { return nil }
            guard result.succeeded else {
                throw ClaudeAccountError.rejected(
                    "The selected machine could not copy the session transcript.")
            }
            return result.stdoutText
        }
        let result = try await CLICommandRunner.run(
            CLICommandRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                environment: CLIToolEnvironment.sanitized(), timeout: 30,
                maximumOutputBytes: 65_536, discardsStandardError: true),
            onLine: { _ in })
        if result.terminationStatus == ClaudeTranscriptCommand.notFoundStatus { return nil }
        guard result.terminationStatus == 0 else {
            throw ClaudeAccountError.rejected("Edith could not copy the session transcript.")
        }
        return result.standardOutput
    }

    private static func machine(for agent: HerdrAgent) throws -> Machine? {
        guard !agent.machineIsLocal else { return nil }
        guard
            let machine = MachineRegistry.machines().first(where: {
                $0.id.uuidString == agent.machineID
            })
        else { throw HerdrAgentCloseError.machineUnavailable }
        return machine
    }
}
