import EdithExtensionSupport
import EdithExtensionUI
import Foundation

struct HerdrDiffSessionState: Codable {
    let worktree: QuinjetWorktree?
    let projectName: String?
    let terminal: OwnedTerminalDescriptor
}

@MainActor enum HerdrShellLaunch {
    static func prepare(target: PaneTarget, store: HerdrStore) async throws -> TerminalLaunchRequest
    {
        guard Bundle.main.bundleURL.pathExtension != "appex" else {
            throw ExtensionPeerError.rejected("Only the owning engine can prepare a shell.")
        }
        if target.machineID == Machine.localID {
            var environment = CLIToolEnvironment.sanitized()
            if let fixture = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] {
                environment["HOME"] = fixture
                environment["ZDOTDIR"] = fixture
                environment["HISTFILE"] = "/dev/null"
            }
            return .init(
                executable: "/bin/zsh", arguments: ["-l"],
                environment: environment.map { $0.key + "=" + $0.value })
        }
        guard let machine = MachineRegistry.machines().first(where: { $0.id == target.machineID })
        else {
            throw ExtensionPeerError.unavailable
        }
        let connection = try await store.connection(for: machine)
        let command = target.argument.map {
            "cd -- " + POSIXQuote.quote($0) + " && exec \"$SHELL\" -l"
        }
        return .init(
            executable: SSHConnection.executable.path,
            arguments: try connection.terminalArguments(remoteCommand: command),
            environment: connection.terminalEnvironment())
    }
}

extension HerdrStore {
    func connectTerminal(for tab: HerdrOpenTab) async throws {
        let generation = tab.holder.generation
        if let terminalClient {
            let data = try await terminalClient(
                "herdr.terminal.open",
                JSONSerialization.data(withJSONObject: ["agentID": tab.id]))
            try Task.checkCancellation()
            guard tab.holder.generation == generation else { throw CancellationError() }
            let descriptor = try JSONDecoder().decode(OwnedTerminalDescriptor.self, from: data)
            if tab.holder.descriptor != descriptor {
                tab.holder.reset()
                tab.holder.bind(
                    try OwnedTerminalClient(descriptor: descriptor, invoke: terminalClient))
            }
            return
        }
        guard Bundle.main.bundleURL.pathExtension != "appex" else {
            throw ExtensionPeerError.unavailable
        }
        let request = try await attachRequest(
            for: tab,
            environment: QuinjetOperationExecution.terminalEnvironment())
        try Task.checkCancellation()
        guard tab.holder.generation == generation else { throw CancellationError() }
        tab.holder.start(
            executable: request.executable, arguments: request.arguments,
            environment: request.environment, allowsLocalFileLinks: tab.agent.machineIsLocal)
        guard tab.holder.descriptor != nil else { throw ExtensionPeerError.unavailable }
    }

    func connectTerminal(for terminal: HerdrPanelTerminal) async throws {
        let generation = terminal.holder.generation
        if let terminalClient {
            let data = try await terminalClient(
                "herdr.panel.open",
                JSONSerialization.data(withJSONObject: ["terminalID": terminal.id]))
            try Task.checkCancellation()
            guard terminal.holder.generation == generation else { throw CancellationError() }
            let descriptor = try JSONDecoder().decode(OwnedTerminalDescriptor.self, from: data)
            if terminal.holder.descriptor != descriptor {
                terminal.holder.reset()
                terminal.holder.bind(
                    try OwnedTerminalClient(descriptor: descriptor, invoke: terminalClient))
            }
            return
        }
        guard Bundle.main.bundleURL.pathExtension != "appex" else {
            throw ExtensionPeerError.unavailable
        }
        let request = try await attachRequest(
            for: terminal,
            environment: QuinjetOperationExecution.terminalEnvironment())
        try Task.checkCancellation()
        guard terminal.holder.generation == generation else { throw CancellationError() }
        terminal.holder.start(
            executable: request.executable, arguments: request.arguments,
            environment: request.environment, allowsLocalFileLinks: terminal.host.isLocal)
        guard terminal.holder.descriptor != nil else { throw ExtensionPeerError.unavailable }
    }

    func connectShell(
        _ holder: TerminalSessionHolder, paneID: UUID, target: PaneTarget,
        prepare: @MainActor (PaneTarget, HerdrStore) async throws -> TerminalLaunchRequest =
            HerdrShellLaunch.prepare
    ) async throws {
        let generation = holder.generation
        if let terminalClient {
            var value: [String: Any] = [
                "paneID": paneID.uuidString, "machineID": target.machineID.uuidString,
            ]
            if let directory = target.argument { value["directory"] = directory }
            let data = try await terminalClient(
                "herdr.shell.open", JSONSerialization.data(withJSONObject: value))
            try Task.checkCancellation()
            guard holder.generation == generation else { throw CancellationError() }
            let descriptor = try JSONDecoder().decode(OwnedTerminalDescriptor.self, from: data)
            if holder.descriptor != descriptor {
                holder.reset()
                holder.bind(try OwnedTerminalClient(descriptor: descriptor, invoke: terminalClient))
            }
            return
        }
        let request = try await prepare(target, self)
        try Task.checkCancellation()
        guard holder.generation == generation else { throw CancellationError() }
        holder.start(
            executable: request.executable, arguments: request.arguments,
            environment: request.environment,
            currentDirectory: target.machineID == Machine.localID ? target.argument : nil,
            allowsLocalFileLinks: target.machineID == Machine.localID)
        guard holder.descriptor != nil else { throw ExtensionPeerError.unavailable }
    }

    func prepareDiff(
        for tab: HerdrOpenTab, appearance: QuinjetAppearance,
        restarting: Bool, launchEnabled: Bool
    ) async {
        do {
            if let terminalClient {
                let data = try await terminalClient(
                    "herdr.diff.open",
                    JSONSerialization.data(withJSONObject: [
                        "agentID": tab.id,
                        "appearance": appearance.rawValue, "restart": restarting,
                    ]))
                try Task.checkCancellation()
                let state = try JSONDecoder().decode(HerdrDiffSessionState.self, from: data)
                try tab.quinjet.adopt(state, invoke: terminalClient)
                return
            }
            guard Bundle.main.bundleURL.pathExtension != "appex" else {
                throw ExtensionPeerError.unavailable
            }
            let remote = try await quinjetRemote(for: tab)
            let configuration = quinjetConfiguration(appearance: appearance)
            if restarting {
                await tab.quinjet.restart(
                    directory: tab.agent.cwd, remote: remote,
                    configuration: configuration, launchEnabled: launchEnabled)
            } else {
                await tab.quinjet.prepare(
                    directory: tab.agent.cwd, remote: remote,
                    configuration: configuration, launchEnabled: launchEnabled)
            }
        } catch is CancellationError {} catch {
            tab.quinjet.errorMessage = error.localizedDescription
        }
    }
}
