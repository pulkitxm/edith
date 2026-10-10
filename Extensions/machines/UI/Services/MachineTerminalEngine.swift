import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import GhosttyTerminal

@MainActor final class MachineTerminalEngine {
    private struct Terminal {
        let machineID: UUID
        let presentationID: UUID?
        let tabID: UUID
        let pty: MachinePTY
        var touched = ContinuousClock.now
        var link: (UUID, TerminalLinkResolution)?
    }
    private struct Registration {
        let machineID: UUID
        let presentationID: UUID
        var tabIDs: Set<UUID>
        var touched = ContinuousClock.now
    }
    private let drops = MachineTerminalDropEngine()
    private var registrations: [UUID: Registration] = [:]
    private let openURL: (URL) -> Bool
    private let session: (UUID) throws -> MachineSession
    private let launch:
        @MainActor (MachineSession, MachineTerminalRequest) throws -> MachinePTYLaunch
    private let interactiveLaunch:
        @MainActor (Machine, [String], [String]) throws -> MachinePTYLaunch
    private var cliPTYs: [UUID: MachinePTY] = [:]
    private var terminals: [UUID: Terminal] = [:]
    private var retired: [MachinePTY] = []
    private var reaper: Task<Void, Never>?
    private var stopped = false

    init(
        session: @escaping (UUID) throws -> MachineSession,
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        launch:
            @escaping @MainActor (MachineSession, MachineTerminalRequest) throws -> MachinePTYLaunch =
            MachineTerminalEngine.originalLaunch,
        interactiveLaunch:
            @escaping @MainActor (Machine, [String], [String]) throws -> MachinePTYLaunch = {
                _, arguments, environment in
                MachinePTYLaunch(
                    executable: SSHConnection.executable.path, arguments: arguments,
                    environment: TerminalLaunchPlan.environment(
                        base: ProcessInfo.processInfo.environment, shell: "/bin/zsh") + environment,
                    currentDirectory: NSHomeDirectory(), startupCommand: nil)
            }
    ) {
        self.openURL = openURL
        self.session = session
        self.launch = launch
        self.interactiveLaunch = interactiveLaunch
    }

    private static func originalLaunch(_ session: MachineSession, _ request: MachineTerminalRequest)
        throws -> MachinePTYLaunch
    {
        let environment = TerminalLaunchPlan.environment(
            base: ProcessInfo.processInfo.environment, shell: "/bin/zsh")
        if let containerID = request.containerID {
            guard session.containers.contains(where: { $0.id == containerID }) else {
                throw MachineUIError.invalidRequest
            }
            if session.isLocal {
                return MachinePTYLaunch(
                    executable: "/bin/sh",
                    arguments: [
                        "-c",
                        MachineExecOperationExecution.dockerShellCommand(
                            containerID: containerID, platform: session.remotePlatform ?? .darwin),
                    ], environment: environment, currentDirectory: NSHomeDirectory(),
                    startupCommand: nil)
            }
            guard let connection = session.connectionRef else { throw MachineUIError.unavailable }
            let launch = MachineExecOperationExecution.dockerShellLaunch(
                containerID: containerID, connection: connection, environment: environment)
            return MachinePTYLaunch(
                executable: launch.executable, arguments: launch.arguments,
                environment: launch.environment, currentDirectory: NSHomeDirectory(),
                startupCommand: nil)
        }
        guard session.isLocal || session.state.isConnected,
            let launch = MachineTerminalLaunchPlan.make(
                isLocal: session.isLocal, connection: session.connectionRef,
                environment: environment,
                context: MachineTerminalContext(startingDirectory: request.directory),
                platform: session.remotePlatform ?? .linux, windowsShell: request.windowsShell)
        else { throw MachineUIError.unavailable }
        return MachinePTYLaunch(
            executable: launch.executable, arguments: launch.arguments,
            environment: launch.environment,
            currentDirectory: launch.currentDirectory ?? NSHomeDirectory(), startupCommand: nil)
    }

    func execute(_ request: MachineTerminalRequest) async throws -> MachineTerminalFrame {
        try request.validate()
        guard !stopped else { throw MachineUIError.unavailable }
        switch request.operation {
        case .register:
            guard let presentationID = request.presentationID,
                registrations.count < 128 || registrations[request.tabID] != nil
            else { throw MachineUIError.invalidRequest }
            if let existing = registrations[request.tabID] {
                guard existing.machineID == request.machineID,
                    existing.presentationID == presentationID
                else { throw MachineUIError.invalidRequest }
            }
            registrations[request.tabID] = Registration(
                machineID: request.machineID, presentationID: presentationID,
                tabIDs: Set(request.tabIDs))
            startReaper()
            return MachineTerminalFrame()
        case .unregister:
            if let existing = registrations[request.tabID] {
                guard existing.machineID == request.machineID,
                    existing.presentationID == request.presentationID
                else { throw MachineUIError.invalidRequest }
                registrations.removeValue(forKey: request.tabID)
            }
            return MachineTerminalFrame()
        case .heartbeat:
            guard let presentationID = request.presentationID else {
                throw MachineUIError.invalidRequest
            }
            for (id, entry) in registrations where entry.presentationID == presentationID {
                registrations[id]?.touched = .now
            }
            return MachineTerminalFrame()
        case .open:
            guard terminals.count < 64,
                !terminals.values.contains(where: { $0.tabID == request.tabID })
            else { throw MachineUIError.unavailable }
            let session = try session(request.machineID)
            let pty = try MachinePTY(
                launch: launch(session, request), columns: request.columns, rows: request.rows)
            let handle = UUID()
            terminals[handle] = Terminal(
                machineID: session.id, presentationID: request.presentationID, tabID: request.tabID,
                pty: pty)
            startReaper()
            return MachineTerminalFrame(handle: handle)
        case .upload:
            guard let connection = try session(request.machineID).connectionRef else {
                throw MachineUIError.unavailable
            }
            let paths = try await TerminalDropTransfer.upload(
                request.paths.map { URL(fileURLWithPath: $0) }, over: connection)
            try Task.checkCancellation()
            return MachineTerminalFrame(paths: paths)
        case .shells:
            let session = try session(request.machineID)
            guard session.remotePlatform == .windows else {
                return MachineTerminalFrame(shells: [.automatic])
            }
            let text = try await session.runCommand(
                WindowsTerminalCommands.availableShells(), timeout: 10
            ).get()
            return MachineTerminalFrame(
                shells: [.automatic] + WindowsTerminalCommands.parseAvailableShells(text))
        case .read, .input, .resize, .close, .resolveLink, .openLink, .dropBegin, .dropWrite,
            .dropFinish, .dropCancel, .dropPaths:
            guard let handle = request.handle, var terminal = terminals[handle],
                terminal.machineID == request.machineID, terminal.tabID == request.tabID,
                terminal.presentationID == request.presentationID
            else { throw MachineUIError.invalidRequest }
            terminal.touched = .now
            terminals[handle] = terminal
            switch request.operation {
            case .read:
                let output = try terminal.pty.read(after: request.offset)
                return MachineTerminalFrame(
                    handle: handle, bytes: output.bytes, nextOffset: output.nextOffset,
                    exitCode: output.exitCode, canonical: output.canonical, echo: output.echo)
            case .dropBegin, .dropWrite, .dropFinish, .dropCancel, .dropPaths:
                return try await drops.execute(request, session: session(request.machineID))
            case .resolveLink:
                let owner = try session(request.machineID)
                let resolution = TerminalLinkResolution.resolve(
                    request.target, directory: request.directory ?? NSHomeDirectory(),
                    untrusted: request.untrusted, allowsLocalFiles: owner.isLocal)
                let id = UUID()
                terminals[handle]?.link = (id, resolution)
                return MachineTerminalFrame(
                    handle: handle, linkID: id, link: try JSONEncoder().encode(resolution))
            case .openLink:
                guard let id = request.linkID, let (expected, resolution) = terminal.link,
                    id == expected, resolution.disposition != .deny,
                    let url = URL(string: resolution.target)
                else { throw MachineUIError.invalidRequest }
                terminals[handle]?.link = nil
                guard openURL(url) else {
                    throw MachineUIFailure(message: "The terminal target could not be opened.")
                }
            case .input: try await send(request.bytes, to: terminal.pty)
            case .resize: try terminal.pty.resize(columns: request.columns, rows: request.rows)
            case .close:
                drops.close(handle)
                terminals.removeValue(forKey: handle)
                await terminal.pty.closeAndWait()
            default: throw MachineUIError.invalidRequest
            }
            return MachineTerminalFrame(handle: handle)
        }
    }

    func broadcast(machineID: UUID, plan: MachineBroadcastPlan, requestID: String) async throws
        -> [String: Any]
    {
        let tabs = Set(registrations.values.filter { $0.machineID == machineID }.flatMap(\.tabIDs))
        let matches = terminals.values.filter {
            $0.machineID == machineID && tabs.contains($0.tabID)
        }
        guard !tabs.isEmpty else {
            return [
                MachineTerminalBroadcastIPC.requestIDKey: requestID,
                MachineTerminalBroadcastIPC.okKey: false,
                MachineTerminalBroadcastIPC.errorCodeKey: MachineTerminalBroadcastIPC
                    .noOpenTabsCode,
                MachineTerminalBroadcastIPC.errorKey: "That machine has no open terminal tabs.",
            ]
        }
        var sent = 0
        for terminal in matches {
            try terminal.pty.poll()
            if terminal.pty.exitCode == nil {
                try await send(Data(plan.terminalInput.utf8), to: terminal.pty); sent += 1
            }
        }
        let unavailable = tabs.count - sent
        let delivery = MachineTerminalBroadcastDelivery(sent: sent, unavailable: unavailable)
        return [
            MachineTerminalBroadcastIPC.requestIDKey: requestID,
            MachineTerminalBroadcastIPC.okKey: sent > 0 && unavailable == 0,
            MachineTerminalBroadcastIPC.machineIDKey: machineID.uuidString,
            MachineTerminalBroadcastIPC.commandKey: plan.command,
            MachineTerminalBroadcastIPC.tabCountKey: sent,
            MachineTerminalBroadcastIPC.unavailableTabCountKey: unavailable,
            MachineTerminalBroadcastIPC.errorCodeKey: sent == 0
                ? MachineTerminalBroadcastIPC.noLiveTabsCode
                : MachineTerminalBroadcastIPC.partialDeliveryCode,
            MachineTerminalBroadcastIPC.errorKey: TerminalTabRegistry.failureMessage(for: delivery),
        ]
    }

    private func send(_ bytes: Data, to pty: MachinePTY) async throws {
        guard bytes.count <= 262_144 else { throw MachineUIError.invalidRequest }
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            guard !stopped, ContinuousClock.now < deadline else { throw MachineUIError.unavailable }
            try pty.poll()
            guard pty.exitCode == nil else { throw MachineUIError.unavailable }
            let count = min(pty.inputCapacity, bytes.count - offset)
            if count > 0 {
                try pty.send(bytes.subdata(in: offset..<offset + count)); offset += count
            } else {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    func runCLI(machine: Machine, arguments: [String], environment: [String]) async throws -> Int32
    {
        guard !stopped, cliPTYs.count < 8 else { throw MachineUIError.unavailable }
        let caller =
            MachineWorkingDirectory.terminalSession.flatMap(UUID.init(uuidString:)) ?? UUID()
        guard cliPTYs[caller] == nil else { throw MachineUIError.unavailable }
        let pty = try MachinePTY(launch: interactiveLaunch(machine, arguments, environment))
        cliPTYs[caller] = pty
        let input = ExtensionCLIContext.request?.standardInput ?? Data()
        var sent = 0
        var cursor: UInt64 = 0
        do {
            while true {
                try Task.checkCancellation()
                try pty.poll()
                let count = min(pty.inputCapacity, input.count - sent)
                if count > 0 {
                    try pty.send(input.subdata(in: sent..<(sent + count))); sent += count
                }
                let output = try pty.read(after: cursor)
                cursor = output.nextOffset
                if !output.bytes.isEmpty { CLIOut.raw(output.bytes) }
                if let code = output.exitCode {
                    cliPTYs.removeValue(forKey: caller)
                    await pty.closeAndWait()
                    return code
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch {
            cliPTYs.removeValue(forKey: caller)
            await pty.closeAndWait()
            throw error
        }
    }

    private struct CLIInput: Decodable {
        let session: UUID
        let bytes: Data
    }

    private struct CLIResize: Decodable {
        let session: UUID
        let columns: UInt16
        let rows: UInt16
    }

    func cliInvoke(_ operation: String, payload: Data) throws -> Data {
        guard !stopped, payload.count <= 32_768 else { throw MachineUIError.unavailable }
        switch operation {
        case "machines.cli.pty.input":
            let input = try JSONDecoder().decode(CLIInput.self, from: payload)
            guard let pty = cliPTYs[input.session], !input.bytes.isEmpty,
                input.bytes.count <= 16_384
            else { throw MachineUIError.invalidRequest }
            try pty.send(input.bytes)
        case "machines.cli.pty.resize":
            let value = try JSONDecoder().decode(CLIResize.self, from: payload)
            guard let pty = cliPTYs[value.session], (1...1000).contains(value.rows),
                (1...1000).contains(value.columns)
            else { throw MachineUIError.invalidRequest }
            try pty.resize(columns: value.columns, rows: value.rows)
        default: throw MachineUIError.invalidRequest
        }
        return Data("{}".utf8)
    }

    private func startReaper() {
        guard reaper == nil else { return }
        reaper = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, !stopped else { return }
                drops.expire()
                for (handle, terminal) in terminals
                where terminal.touched.duration(to: .now) > .seconds(10) {
                    drops.close(handle)
                    terminal.pty.close(); retired.append(terminal.pty);
                    terminals.removeValue(forKey: handle)
                }
                registrations = registrations.filter {
                    $0.value.touched.duration(to: .now) <= .seconds(10)
                }
                let children = retired; retired = []
                for pty in children { await pty.closeAndWait() }
            }
        }
    }

    func release(_ presentation: UUID) {
        for id in terminals.keys.filter({ terminals[$0]?.presentationID == presentation }) {
            if let terminal = terminals.removeValue(forKey: id) {
                drops.close(id)
                terminal.pty.close(); retired.append(terminal.pty)
            }
        }
        registrations = registrations.filter { $0.value.presentationID != presentation }
    }

    func shutdown() async {
        stopped = true
        drops.shutdown()
        reaper?.cancel(); reaper = nil
        let children = terminals.values.map(\.pty) + retired + Array(cliPTYs.values)
        terminals = [:]; retired = []; cliPTYs = [:]; registrations = [:]
        for pty in children { pty.close() }
        for pty in children { await pty.closeAndWait() }
    }
}
