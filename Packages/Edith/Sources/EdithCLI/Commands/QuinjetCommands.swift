import ArgumentParser
import EdithKit
import Foundation

struct QuinjetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quinjet",
        abstract: "Discover and open Quinjet review workspaces.",
        subcommands: [
            QuinjetProjectsCommand.self, QuinjetWorktreesCommand.self,
            QuinjetOpenCommand.self, QuinjetLaunchCommand.self,
            QuinjetStatusCommand.self, QuinjetSessionsCommand.self,
            QuinjetNewCommand.self,
            QuinjetFocusCommand.self, QuinjetCloseCommand.self,
            QuinjetRestartCommand.self, QuinjetSwitchCommand.self,
        ],
        defaultSubcommand: QuinjetProjectsCommand.self)
}

struct QuinjetTargetOptions: ParsableArguments {
    @Option(name: .long, help: "Target a configured machine, or `local` for this Mac.")
    var machine: String?
}

struct QuinjetLaunchOptions: ParsableArguments {
    @Option(help: "Quinjet theme name.")
    var theme: String?

    @Option(help: "Choose `light` or `dark`.")
    var appearance: String?

    @Flag(name: .long, help: "Open the session in cmux.")
    var cmux = false

    @Flag(name: .long, help: "Open the session in the current terminal.")
    var embedded = false

    func configuration() throws -> QuinjetLaunchConfiguration {
        guard !(cmux && embedded) else {
            throw CLIFailure.usage("--cmux and --embedded cannot be used together")
        }
        let preferred = QuinjetLaunchConfiguration.preferred(
            sharedDefaults: CLIEnvironment.sharedDefaults,
            standardDefaults: CLIEnvironment.standardDefaults)
        let themeName = theme ?? preferred.theme.rawValue
        guard let theme = QuinjetTheme(rawValue: themeName) else {
            throw CLIFailure.usage(
                "unknown Quinjet theme \(themeName)",
                hint: "themes: " + QuinjetTheme.allCases.map(\.rawValue).joined(separator: ", "))
        }
        let appearanceName = appearance ?? preferred.appearance.rawValue
        guard let appearance = QuinjetAppearance(rawValue: appearanceName) else {
            throw CLIFailure.usage(
                "unknown Quinjet appearance \(appearanceName)", hint: "choose light or dark")
        }
        let terminal = cmux ? QuinjetTerminal.cmux : embedded ? .embedded : preferred.terminal
        return QuinjetLaunchConfiguration(
            terminal: terminal, theme: theme, appearance: appearance)
    }
}

struct QuinjetProjectsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "projects", abstract: QuinjetOperation.projects.descriptor.summary)

    @Flag(name: .long, help: "Emit stable JSON on stdout.")
    var json = false

    @OptionGroup var target: QuinjetTargetOptions

    func run() async throws {
        try await execute {
            let target = try await QuinjetCLIEnvironment.resolveTarget(target.machine)
            let projects = try await QuinjetCLI.resolved {
                try await QuinjetOperationExecution.projects(
                    remote: target.remote, using: QuinjetCLIEnvironment.client())
            }
            QuinjetCLI.renderProjects(projects, target: target, json: json)
        }
    }
}

struct QuinjetWorktreesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "worktrees", abstract: QuinjetOperation.worktrees.descriptor.summary)

    @Flag(name: .long, help: "Emit stable JSON on stdout.")
    var json = false

    @OptionGroup var target: QuinjetTargetOptions

    @Argument(help: "Project or worktree path.")
    var path: String

    func run() async throws {
        try await execute {
            let target = try await QuinjetCLIEnvironment.resolveTarget(target.machine)
            let worktrees = try await QuinjetCLI.resolved {
                try await QuinjetOperationExecution.worktrees(
                    at: path, remote: target.remote, using: QuinjetCLIEnvironment.client())
            }
            QuinjetCLI.renderWorktrees(worktrees, target: target, json: json)
        }
    }
}

struct QuinjetOpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open", abstract: QuinjetOperation.open.descriptor.summary)

    @Flag(name: .long, help: "Emit stable JSON on stdout.")
    var json = false

    @OptionGroup var target: QuinjetTargetOptions
    @OptionGroup var launch: QuinjetLaunchOptions

    @Argument(help: "Project or worktree path.")
    var path: String

    func run() async throws {
        try await execute {
            let plan = try await QuinjetCLI.plan(
                path: path, machine: target.machine, launch: launch)
            QuinjetCLI.renderPlan(plan, launched: false, json: json)
        }
    }
}

struct QuinjetLaunchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch", abstract: QuinjetOperation.launch.descriptor.summary)

    @OptionGroup var target: QuinjetTargetOptions
    @OptionGroup var launch: QuinjetLaunchOptions

    @Flag(name: .long, help: "Emit stable JSON on stdout.")
    var json = false

    @Argument(help: "Project or worktree path.")
    var path: String

    func run() async throws {
        try await execute {
            let plan = try await QuinjetCLI.plan(
                path: path, machine: target.machine, launch: launch)
            let status = try await QuinjetCLIEnvironment.launch(plan.request, json)
            guard status == 0 else { throw ExitCode(status) }
            if json {
                QuinjetCLI.renderPlan(plan, launched: true, json: true)
            } else if plan.request.terminal == .cmux {
                CLIOut.out("Opened \(plan.selection.worktree.displayName) in cmux.")
            }
        }
    }
}

enum QuinjetSessionCLI {
    static func request(
        _ operation: QuinjetSessionOperation, session: String? = nil,
        worktreePath: String? = nil, timeout: TimeInterval = 8
    ) async throws -> QuinjetSessionResult {
        try AppBridge.requireMainApp("native Quinjet session control")
        let requestID = UUID().uuidString
        var payload: [String: Any] = [
            QuinjetSessionIPC.requestIDKey: requestID,
            QuinjetSessionIPC.operationKey: operation.rawValue,
        ]
        if let session { payload[QuinjetSessionIPC.sessionKey] = session }
        if let worktreePath { payload[QuinjetSessionIPC.worktreePathKey] = worktreePath }
        let requestPayload = payload
        guard
            let reply = await AppBridge.awaitReply(
                IPC.Name.quinjetSessionOperationResult, timeout: timeout,
                matching: { $0[QuinjetSessionIPC.requestIDKey] as? String == requestID },
                trigger: {
                    AppBridge.post(
                        IPC.Name.requestQuinjetSessionOperation, userInfo: requestPayload)
                })
        else {
            throw AppBridge.silence(
                "native Quinjet sessions", extensionKey: AppStorageKeys.Tabs.quinjetEnabled)
        }
        guard reply[QuinjetSessionIPC.okKey] as? Bool == true else {
            throw failure(reply)
        }
        guard let raw = reply[QuinjetSessionIPC.payloadKey] as? String,
            let data = raw.data(using: .utf8),
            let result = try? JSONDecoder().decode(QuinjetSessionResult.self, from: data)
        else {
            throw CLIFailure(
                "Edith returned an invalid Quinjet session result",
                hint: "rebuild and reopen Edith, then retry")
        }
        return result
    }

    static func session(
        matching selector: String?, in result: QuinjetSessionResult
    ) throws -> QuinjetSessionState {
        let query = selector?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if query.isEmpty {
            guard
                let selected = result.sessions.first(where: { $0.id == result.selectedSessionID })
            else {
                throw CLIFailure.notFound("there is no selected native Quinjet session")
            }
            return selected
        }
        if let index = Int(query), let found = result.sessions.first(where: { $0.index == index }) {
            return found
        }
        let matches = result.sessions.filter {
            $0.id.caseInsensitiveCompare(query) == .orderedSame
                || $0.title.caseInsensitiveCompare(query) == .orderedSame
                || $0.worktreePath == query
                || $0.branch?.caseInsensitiveCompare(query) == .orderedSame
        }
        guard matches.count == 1, let found = matches.first else {
            throw CLIFailure.notFound(
                "no native Quinjet session matches \(query)",
                hint: "run `ed quinjet sessions` and use its session number")
        }
        return found
    }

    static func render(_ result: QuinjetSessionResult, json: Bool) throws {
        guard !json else {
            CLIOut.json(resultJSON(result))
            return
        }
        switch result.operation {
        case .status:
            renderStatus(try session(matching: result.affectedSessionID, in: result))
        case .sessions:
            renderSessions(result.sessions)
        case .create:
            let state = try session(matching: result.affectedSessionID, in: result)
            CLIOut.out("created session \(state.index): \(state.title)")
        case .focus:
            let state = try session(matching: result.affectedSessionID, in: result)
            CLIOut.out("selected session \(state.index): \(state.title)")
        case .close:
            CLIOut.out("closed the Quinjet session")
        case .restart:
            let state = try session(matching: result.affectedSessionID, in: result)
            CLIOut.out("restarted session \(state.index): \(state.title)")
        case .switchWorktree:
            let state = try session(matching: result.affectedSessionID, in: result)
            CLIOut.out("switched session \(state.index) to \(state.worktreePath ?? state.title)")
        }
    }

    static func resultJSON(_ result: QuinjetSessionResult) -> JSONValue {
        .object([
            "operation": .string(result.operation.rawValue),
            "selectedSessionID": .optional(result.selectedSessionID),
            "affectedSessionID": .optional(result.affectedSessionID),
            "sessions": .array(result.sessions.map(json)),
        ])
    }

    static func json(_ session: QuinjetSessionState) -> JSONValue {
        .object([
            "id": .string(session.id), "index": .int(session.index),
            "title": .string(session.title), "selected": .bool(session.selected),
            "state": .string(session.state), "terminal": .optional(session.terminal),
            "project": .optional(session.project),
            "worktreePath": .optional(session.worktreePath),
            "branch": .optional(session.branch), "machine": .string(session.machine),
            "canClose": .bool(session.canClose), "canRestart": .bool(session.canRestart),
            "exitMessage": .optional(session.exitMessage),
        ])
    }

    private static func renderStatus(_ session: QuinjetSessionState) {
        CLIOut.out("session: \(session.index)")
        CLIOut.out("title: \(session.title)")
        CLIOut.out("state: \(session.state)")
        CLIOut.out("terminal: \(session.terminal ?? "none")")
        CLIOut.out("machine: \(session.machine)")
        CLIOut.out("worktree: \(session.worktreePath ?? "none")")
        if let exitMessage = session.exitMessage { CLIOut.out("exit: \(exitMessage)") }
    }

    private static func renderSessions(_ sessions: [QuinjetSessionState]) {
        let rows = sessions.map {
            [
                String($0.index), $0.selected ? "*" : "", $0.title, $0.state,
                $0.terminal ?? "-", $0.worktreePath ?? "-",
            ]
        }
        CLIOut.out(
            TextTable.render(
                headers: ["#", "SELECTED", "SESSION", "STATE", "TERMINAL", "WORKTREE"],
                rows: rows))
    }

    private static func failure(_ reply: [AnyHashable: Any]) -> CLIFailure {
        let message =
            reply[QuinjetSessionIPC.errorKey] as? String
            ?? "Edith could not complete the Quinjet session operation"
        switch reply[QuinjetSessionIPC.errorCodeKey] as? String {
        case QuinjetSessionError.pageUnavailable.code:
            return CLIFailure.unavailable(
                message, hint: "run `ed app reveal quinjet`, then retry")
        case QuinjetSessionError.sessionNotFound("").code:
            return CLIFailure.notFound(
                message, hint: "run `ed quinjet sessions` and use its session number")
        case QuinjetSessionError.worktreeNotFound("").code:
            return CLIFailure.notFound(message)
        case QuinjetSessionError.worktreeRequired.code:
            return CLIFailure.usage(message)
        default:
            return CLIFailure(message)
        }
    }
}

struct QuinjetStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: QuinjetSessionOperation.status.descriptor.summary)

    @Flag(name: .long, help: "Emit stable JSON on stdout.")
    var json = false

    @Argument(help: "A session number, id, title, branch or worktree path.")
    var session: String?

    func run() async throws {
        try await execute {
            let result = try await QuinjetSessionCLI.request(.status, session: session)
            try QuinjetSessionCLI.render(result, json: json)
        }
    }
}

struct QuinjetSessionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sessions", abstract: QuinjetSessionOperation.sessions.descriptor.summary,
        aliases: ["list", "ls"])

    @Flag(name: .long, help: "Emit stable JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let result = try await QuinjetSessionCLI.request(.sessions)
            try QuinjetSessionCLI.render(result, json: json)
        }
    }
}

struct QuinjetNewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "new", abstract: QuinjetSessionOperation.create.descriptor.summary,
        aliases: ["create"])

    @Flag(name: .long, help: "Emit stable JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let result = try await QuinjetSessionCLI.request(.create)
            try QuinjetSessionCLI.render(result, json: json)
        }
    }
}

struct QuinjetFocusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "focus", abstract: QuinjetSessionOperation.focus.descriptor.summary,
        aliases: ["select"])

    @Flag(name: .long, help: "Emit stable JSON on stdout.")
    var json = false

    @Argument(help: "A session number, id, title, branch or worktree path.")
    var session: String

    func run() async throws {
        try await execute {
            let result = try await QuinjetSessionCLI.request(.focus, session: session)
            try QuinjetSessionCLI.render(result, json: json)
        }
    }
}

struct QuinjetCloseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close", abstract: QuinjetSessionOperation.close.descriptor.summary)

    @Flag(name: .long, help: "Emit stable JSON on stdout.")
    var json = false

    @Flag(help: "Actually close the session. Without this nothing is touched.")
    var yes = false

    @Argument(help: "A session number, id, title, branch or worktree path.")
    var session: String

    func run() async throws {
        try await execute {
            let current = try await QuinjetSessionCLI.request(.sessions)
            let target = try QuinjetSessionCLI.session(matching: session, in: current)
            let plan = CLIDestructivePlan(
                action: "close Quinjet session", targets: ["\(target.index): \(target.title)"],
                confirmed: yes, json: json,
                fields: ["sessionID": .string(target.id), "index": .int(target.index)])
            guard plan.shouldApply() else { return }
            let result = try await QuinjetSessionCLI.request(.close, session: target.id)
            plan.finish(
                changed: true, plain: "closed session \(target.index): \(target.title)",
                fields: [
                    "closedSessionID": .string(target.id),
                    "selectedSessionID": .optional(result.selectedSessionID),
                    "remaining": .int(result.sessions.count),
                ])
        }
    }
}

struct QuinjetRestartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart", abstract: QuinjetSessionOperation.restart.descriptor.summary)

    @Flag(name: .long, help: "Emit stable JSON on stdout.")
    var json = false

    @Argument(help: "A session selector; the selected session without one.")
    var session: String?

    func run() async throws {
        try await execute {
            let result = try await QuinjetSessionCLI.request(.restart, session: session)
            try QuinjetSessionCLI.render(result, json: json)
        }
    }
}

struct QuinjetSwitchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "switch", abstract: QuinjetSessionOperation.switchWorktree.descriptor.summary)

    @Flag(name: .long, help: "Emit stable JSON on stdout.")
    var json = false

    @Argument(help: "A session number, id, title, branch or current worktree path.")
    var session: String

    @Argument(help: "The project or worktree path to open in place.")
    var path: String

    func run() async throws {
        try await execute {
            let result = try await QuinjetSessionCLI.request(
                .switchWorktree, session: session, worktreePath: path, timeout: 20)
            try QuinjetSessionCLI.render(result, json: json)
        }
    }
}

struct QuinjetCommandTarget: Sendable {
    let name: String
    let local: Bool
    let remote: QuinjetRemote?
    let connection: SSHConnection?

    static func resolve(_ query: String?) async throws -> QuinjetCommandTarget {
        if query == nil || ["local", "this-mac", "thismac"].contains(query?.lowercased() ?? "") {
            return QuinjetCommandTarget(name: "This Mac", local: true, remote: nil, connection: nil)
        }
        let machine = try MachineResolver.machine(query ?? "")
        let connection = SSHConnection(machine: machine, controlSocketMode: .shared)
        do {
            try await connection.connect()
        } catch {
            throw CLIFailure.unavailable(
                "could not reach \(machine.name): \(error.localizedDescription)",
                hint: "check the machine is awake and reachable, then retry")
        }
        return QuinjetCommandTarget(
            name: machine.name, local: false,
            remote: QuinjetRemote(
                machineID: machine.id, machineName: machine.name, target: machine.sshTarget,
                controlPath: connection.controlSocketPath),
            connection: connection)
    }
}

struct QuinjetCLIPlan: Sendable {
    let target: QuinjetCommandTarget
    let selection: QuinjetOpenSelection
    let request: QuinjetLaunchRequest
}

enum QuinjetCLIEnvironment {
    typealias Launcher = @Sendable (QuinjetLaunchRequest, Bool) async throws -> Int32

    nonisolated(unsafe) static var client: @Sendable () -> QuinjetClient = { .live }
    nonisolated(unsafe) static var cmuxExecutable: @Sendable () -> URL? = {
        QuinjetCMUX.executable()
    }
    nonisolated(unsafe) static var resolveTarget:
        @Sendable (String?) async throws -> QuinjetCommandTarget = {
            try await QuinjetCommandTarget.resolve($0)
        }
    nonisolated(unsafe) static var launch: Launcher = { request, noninteractive in
        try await launchLive(request, noninteractive: noninteractive)
    }

    static func reset() {
        client = { .live }
        cmuxExecutable = { QuinjetCMUX.executable() }
        resolveTarget = { try await QuinjetCommandTarget.resolve($0) }
        launch = { try await launchLive($0, noninteractive: $1) }
    }

    private static func launchLive(
        _ request: QuinjetLaunchRequest, noninteractive: Bool
    ) async throws -> Int32 {
        if request.terminal == .cmux {
            guard cmuxExecutable() != nil else {
                throw CLIFailure.unavailable(
                    "cmux is not installed in Applications",
                    hint: "install cmux, or omit --cmux to launch in this terminal")
            }
            do {
                _ = try CLIEnvironment.runAppleScript(
                    QuinjetCMUX.launchScript(request: request), 15)
                return 0
            } catch {
                throw CLIFailure.unavailable(
                    "cmux could not open Quinjet", hint: error.localizedDescription)
            }
        }
        let process = Process()
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = CLIToolEnvironment.sanitized()
        process.standardInput = noninteractive ? FileHandle.nullDevice : FileHandle.standardInput
        process.standardOutput =
            noninteractive ? CLIOut.stderrHandle : FileHandle.standardOutput
        process.standardError = noninteractive ? CLIOut.stderrHandle : FileHandle.standardError
        if let currentDirectory = request.currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }
        do {
            try process.run()
        } catch {
            throw CLIFailure.unavailable(
                "Quinjet could not start", hint: error.localizedDescription)
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

enum QuinjetCLI {
    static func plan(
        path: String, machine: String?, launch: QuinjetLaunchOptions
    ) async throws -> QuinjetCLIPlan {
        let configuration = try launch.configuration()
        let target = try await QuinjetCLIEnvironment.resolveTarget(machine)
        let selection = try await resolved {
            try await QuinjetOperationExecution.openSelection(
                at: path, remote: target.remote, using: QuinjetCLIEnvironment.client())
        }
        guard let executable = CLIEnvironment.executableNamed("quinjet") else {
            throw missingTool()
        }
        let request = QuinjetOperationExecution.launchRequest(
            executableURL: executable, worktreePath: selection.worktree.path,
            remote: target.remote, configuration: configuration, managedByEdith: false,
            localHomeDirectory: CLIEnvironment.homeDirectory.path)
        return QuinjetCLIPlan(target: target, selection: selection, request: request)
    }

    static func resolved<Value>(_ body: () async throws -> Value) async throws -> Value {
        do {
            return try await body()
        } catch let error as QuinjetClientError {
            switch error {
            case .notInstalled:
                throw missingTool()
            case let .launchFailed(message):
                throw CLIFailure.unavailable("Quinjet could not start", hint: message)
            case let .commandFailed(message):
                throw CLIFailure("Quinjet command failed", hint: message)
            case .invalidResponse:
                throw CLIFailure(
                    "Quinjet returned malformed JSON",
                    hint: "update Quinjet and retry the command")
            }
        } catch let error as QuinjetOperationError {
            throw CLIFailure.notFound(error.localizedDescription)
        }
    }

    static func renderProjects(
        _ projects: [QuinjetProject], target: QuinjetCommandTarget, json: Bool
    ) {
        guard !json else {
            CLIOut.json(
                .object([
                    "local": .bool(target.local), "machine": .string(target.name),
                    "projects": .array(projects.map(projectJSON)),
                ]))
            return
        }
        guard !projects.isEmpty else {
            CLIOut.note("no recent Quinjet projects on \(target.name)")
            return
        }
        CLIOut.out(
            TextTable.render(
                headers: ["PROJECT", "WORKTREES", "PATH"],
                rows: projects.map {
                    [$0.name, String($0.availableWorktrees.count), $0.defaultWorktree?.path ?? "-"]
                }))
    }

    static func renderWorktrees(
        _ worktrees: [QuinjetWorktree], target: QuinjetCommandTarget, json: Bool
    ) {
        guard !json else {
            CLIOut.json(
                .object([
                    "local": .bool(target.local), "machine": .string(target.name),
                    "worktrees": .array(worktrees.map(worktreeJSON)),
                ]))
            return
        }
        guard !worktrees.isEmpty else {
            CLIOut.note("no worktrees found on \(target.name)")
            return
        }
        CLIOut.out(
            TextTable.render(
                headers: ["WORKTREE", "PATH", "STATE"],
                rows: worktrees.map {
                    [
                        $0.displayName,
                        $0.path,
                        $0.canOpen ? ($0.current ? "current" : "open") : "unavailable",
                    ]
                }))
    }

    static func renderPlan(_ plan: QuinjetCLIPlan, launched: Bool, json: Bool) {
        guard !json else {
            CLIOut.json(
                .object([
                    "arguments": .strings(plan.request.arguments),
                    "command": .string(plan.request.shellCommand),
                    "currentDirectory": .optional(plan.request.currentDirectory),
                    "executable": .string(plan.request.executableURL.path),
                    "launched": .bool(launched),
                    "local": .bool(plan.target.local),
                    "machine": .string(plan.target.name),
                    "terminal": .string(plan.request.terminal == .cmux ? "cmux" : "current"),
                    "worktree": worktreeJSON(plan.selection.worktree),
                ]))
            return
        }
        CLIOut.out(plan.request.shellCommand)
    }

    private static func projectJSON(_ project: QuinjetProject) -> JSONValue {
        .object([
            "commonDir": .string(project.commonDir), "name": .string(project.name),
            "worktrees": .array(project.worktrees.map(worktreeJSON)),
        ])
    }

    private static func worktreeJSON(_ worktree: QuinjetWorktree) -> JSONValue {
        .object([
            "bare": .bool(worktree.bare), "branch": .optional(worktree.branch),
            "canOpen": .bool(worktree.canOpen), "current": .bool(worktree.current),
            "detached": .bool(worktree.detached), "displayName": .string(worktree.displayName),
            "head": .string(worktree.head), "locked": .optional(worktree.locked),
            "path": .string(worktree.path), "prunable": .optional(worktree.prunable),
        ])
    }

    private static func missingTool() -> CLIFailure {
        CLIFailure.unavailable(
            "Quinjet is not installed",
            hint: "install it with `brew install pulkitxm/tap/quinjet`")
    }
}
