import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation

@MainActor final class QuinjetWorker {
    let model: QuinjetPageModel
    let defaults: UserDefaults
    let client: QuinjetClient
    let terminalSessions = OwnedTerminalSessionRegistry()
    let automaticActions: Bool
    private(set) var isStopped = false
    private var started = false
    private var cliStreams: ExtensionCLIStreams?
    private lazy var uiEngine = QuinjetUIEngine(worker: self)
    private var maintenance: Task<Void, Never>?
    private struct ProjectSelection: Equatable {
        let project: QuinjetProject; let remote: QuinjetRemote?
    }
    private var projects: [UUID: ProjectSelection] = [:]
    private let previewExecutable: @MainActor () -> URL?
    let resolveRemote: @MainActor (UUID) async throws -> QuinjetRemote
    private var worktrees: [UUID: (UUID, QuinjetWorktree, [QuinjetWorktree])] = [:]

    init(
        defaults: UserDefaults = SharedDefaults.store,
        client: QuinjetClient = .live,
        previewExecutable: @escaping @MainActor () -> URL? = QuinjetExecutable.local,
        resolveRemote: @escaping @MainActor (UUID) async throws -> QuinjetRemote = QuinjetWorker
            .savedRemote,
        automaticActions: Bool = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"]
            == nil
    ) {
        self.defaults = defaults
        self.client = client
        self.previewExecutable = previewExecutable
        self.resolveRemote = resolveRemote
        self.automaticActions = automaticActions
        model = QuinjetPageModel(client: client)
        terminalSessions.files.upload = { [weak self] handle, urls in
            guard let self, !self.isStopped, self.terminalSessions.find(handle) != nil,
                let tab = self.model.tabs.first(where: { $0.holder.descriptor?.handle == handle }),
                let remote = tab.remote,
                let connection = self.model.machines.session(for: remote.machineID).connectionRef,
                connection.machine.id == remote.machineID
            else { throw ExtensionPeerError.unavailable }
            return try await TerminalDropTransfer.upload(urls, over: connection)
        }
        QuinjetWorkOwnership.enable()
    }
    func start() async {
        await OwnedTerminalContext.$registry.withValue(terminalSessions) { await startOwned() }
    }

    private func startOwned() async {
        guard !started, !isStopped else { return }
        started = true
        QuinjetPrivacy.shared.start()
        model.setSessionLaunchEnabled(automaticActions)
        guard automaticActions else { return }
        _ = try? await refresh()
        _ = try? await QuinjetMachines.shared.refresh()
        maintenance = QuinjetWorkOwnership.start { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !self.isStopped, !Task.isCancelled else { return }
                try? await QuinjetMachines.shared.refresh()
            }
        }
    }
    func refresh(machineID: UUID? = nil) async throws -> Data {
        let remote: QuinjetRemote?
        if let machineID { remote = try await resolveRemote(machineID) } else { remote = nil }
        let loaded = try await QuinjetOperationExecution.projects(remote: remote, using: client)
        try Task.checkCancellation()
        guard !isStopped, loaded.count <= 1024,
            loaded.allSatisfy({
                $0.commonDir.utf8.count <= 4096 && $0.name.utf8.count <= 1024
                    && !$0.commonDir.utf8.contains(0) && $0.worktrees.count <= 1024
                    && $0.worktrees.allSatisfy(Self.validWorktree)
            })
        else { throw QuinjetClientError.invalidResponse }
        let existing = projects.filter { $0.value.remote?.machineID == remote?.machineID }
        let previous = Dictionary(
            existing.map { ($0.value.project.commonDir, $0.key) },
            uniquingKeysWith: { first, _ in first })
        projects = projects.filter { $0.value.remote?.machineID != remote?.machineID }
        for project in loaded {
            projects[previous[project.commonDir] ?? UUID()] = ProjectSelection(
                project: project, remote: remote)
        }
        guard projects.count <= 1024 else {
            projects.removeAll(); worktrees.removeAll(); throw QuinjetClientError.invalidResponse
        }
        worktrees = worktrees.filter { projects[$0.value.0] != nil }
        if let remote {
            await model.refreshProjects(for: remote)
        } else {
            await model.refreshProjects()
        }
        try Task.checkCancellation()
        return try JSONSerialization.data(withJSONObject: [
            "projects": projects.filter { $0.value.remote?.machineID == remote?.machineID }.sorted {
                $0.value.project.name < $1.value.project.name
            }.map {
                [
                    "id": $0.key.uuidString, "name": $0.value.project.name,
                    "machineID": $0.value.remote?.machineID.uuidString ?? "local",
                ]
            }
        ])
    }
    private static func validWorktree(_ worktree: QuinjetWorktree) -> Bool {
        worktree.path.utf8.count <= 4096 && !worktree.path.utf8.contains(0)
            && worktree.head.utf8.count <= 256
            && (worktree.branch?.utf8.count ?? 0) <= 1024
            && (worktree.locked?.utf8.count ?? 0) <= 1024
            && (worktree.prunable?.utf8.count ?? 0) <= 1024
    }
    private static func savedRemote(_ id: UUID) async throws -> QuinjetRemote {
        guard SurfaceHostContext.current?.activeIDs.contains("machines") == true else {
            throw ExtensionPeerError.unavailable
        }
        try await QuinjetMachines.shared.refresh()
        guard
            let machine = QuinjetMachines.shared.allMachines.first(where: {
                $0.id == id && $0.id != Machine.localID
            })
        else { throw ExtensionPeerError.invalidRequest }
        let session = QuinjetMachines.shared.session(for: id)
        session.start()
        let deadline = ContinuousClock.now + .seconds(30)
        while !session.state.isConnected, ContinuousClock.now < deadline {
            if let failure = session.state.failureMessage {
                throw ExtensionPeerError.rejected(failure)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        guard let connection = session.connectionRef else { throw ExtensionPeerError.unavailable }
        return try await QuinjetRemote.connected(
            machineID: id, machineName: machine.name, target: machine.sshTarget,
            connection: connection)
    }
    func execute(_ command: String, payload: Data) async throws -> Data {
        try await OwnedTerminalContext.$registry.withValue(terminalSessions) {
            try await executeOwned(command, payload: payload)
        }
    }

    private func executeOwned(_ command: String, payload: Data) async throws -> Data {
        guard !isStopped else { throw ExtensionPeerError.unavailable }
        try Task.checkCancellation()
        if command == "quinjet.cli.catalog" {
            guard payload.count <= 16384,
                let value = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                value.isEmpty
            else { throw ExtensionPeerError.invalidRequest }
            return try QuinjetCLICatalog.data()
        }
        if [
            "quinjet.cli.start", "quinjet.cli.read", "quinjet.cli.cancel", "quinjet.cli.end",
            "quinjet.cli.write", "quinjet.cli.resize",
        ]
        .contains(command) {
            if cliStreams == nil { cliStreams = try ExtensionCLIStreams(owner: "quinjet") }
            guard let cliStreams else { throw ExtensionPeerError.unavailable }
            return try QuinjetCLIExecution.invokeStream(
                command, payload: payload,
                worker: self, streams: cliStreams)
        }
        if [
            "quinjet.terminal.read", "quinjet.terminal.input", "quinjet.terminal.resize",
            "quinjet.terminal.close", "quinjet.terminal.link.resolve", "quinjet.terminal.link.open",
        ].contains(command) || OwnedTerminalFiles.admits(command) {
            guard payload.count <= 32768 else { throw ExtensionPeerError.invalidRequest }
            let request = try JSONDecoder().decode(OwnedTerminalRequest.self, from: payload)
            guard let session = terminalSessions.find(request.session) else {
                throw ExtensionPeerError.invalidRequest
            }
            return try await session.execute(command, payload: payload)
        }
        guard payload.count <= 16_384,
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { throw ExtensionPeerError.invalidRequest }
        if command == "quinjet.settings.read" || command == "quinjet.settings.save" {
            return try await QuinjetSettingsEngine.execute(command, object: object, worker: self)
        }
        if command.hasPrefix("quinjet.ui.") {
            return try await uiEngine.execute(command, object: object)
        }
        if command == "quinjet.native.action" {
            guard Set(object.keys) == ["tabID", "action"], let id = object["tabID"] as? String,
                let uuid = UUID(uuidString: id),
                let tab = model.tabs.first(where: { $0.id == uuid }), tab.holder.started,
                let action = object["action"] as? String, QuinjetHostAction(payload: action) != nil,
                model.tabs.count < 32
            else { throw ExtensionPeerError.invalidRequest }
            model.handleHostPayload(action, from: tab)
            return Data("{\"accepted\":true}".utf8)
        }
        guard QuinjetCommandCatalog.admits(command) else { throw ExtensionPeerError.invalidRequest }
        if command == "quinjet.projects" {
            guard Set(object.keys).isSubset(of: ["machineID"]) else {
                throw ExtensionPeerError.invalidRequest
            }
            var machineID: UUID?
            if let supplied = object["machineID"] {
                guard let text = supplied as? String, let id = UUID(uuidString: text) else {
                    throw ExtensionPeerError.invalidRequest
                }
                machineID = id
            }
            return try await refresh(machineID: machineID)
        }
        if command == "quinjet.worktrees" {
            guard Set(object.keys) == ["projectID"], let text = object["projectID"] as? String,
                let id = UUID(uuidString: text), let project = projects[id]
            else { throw ExtensionPeerError.invalidRequest }
            let loaded = try await client.worktrees(
                at: project.project.defaultWorktree?.path ?? project.project.commonDir,
                remote: project.remote
            ).filter(\.canOpen)
            try Task.checkCancellation()
            guard !isStopped, projects[id] == project, loaded.count <= 1024,
                loaded.allSatisfy(Self.validWorktree)
            else { throw QuinjetClientError.invalidResponse }
            worktrees = worktrees.filter { $0.value.0 != id }
            guard worktrees.count + loaded.count <= 1024 else {
                throw QuinjetClientError.invalidResponse
            }
            let items = loaded.map { worktree -> [String: String] in
                let token = UUID()
                worktrees[token] = (id, worktree, loaded)
                return [
                    "id": token.uuidString,
                    "name": worktree.branch ?? QuinjetPath.name(worktree.path),
                ]
            }
            return try JSONSerialization.data(withJSONObject: ["worktrees": items])
        }
        if command == "quinjet.open" || command == "quinjet.select" || command == "quinjet.launch" {
            guard Set(object.keys) == ["worktreeID"], let text = object["worktreeID"] as? String,
                let id = UUID(uuidString: text), let selection = worktrees[id],
                let project = projects[selection.0], let tab = model.selectedTab
            else { throw ExtensionPeerError.invalidRequest }
            if command == "quinjet.open" {
                guard let executable = previewExecutable() else {
                    throw QuinjetClientError.notInstalled
                }
                let request = try QuinjetOperationExecution.launchRequest(
                    executableURL: executable, worktreePath: selection.1.path,
                    remote: project.remote, configuration: .default, managedByEdith: true,
                    localHomeDirectory: ProcessInfo.processInfo.environment[
                        "EDITH_EXTENSION_FIXTURE_HOME"]
                        ?? FileManager.default.homeDirectoryForCurrentUser.path)
                return try JSONSerialization.data(withJSONObject: [
                    "worktreeID": text,
                    "machineID": project.remote?.machineID.uuidString ?? "local",
                    "executable": request.executableURL.path, "arguments": request.arguments,
                    "environment": request.environment, "command": request.shellCommand,
                ])
            }
            model.open(
                selection.1, projectName: project.project.name, available: selection.2,
                remote: project.remote, in: tab,
                launchEnabled: command == "quinjet.launch")
            ExtensionPresentation.showWindow()
            return try JSONEncoder().encode(
                try await model.performSessionOperation(.init(operation: .status)))
        }
        let raw = String(command.dropFirst("quinjet.session.".count))
        guard let operation = QuinjetSessionOperation(rawValue: raw),
            Set(object.keys).isSubset(of: ["sessionID", "worktreeID"])
        else { throw ExtensionPeerError.invalidRequest }
        if operation == .sessions, !object.isEmpty { throw ExtensionPeerError.invalidRequest }
        var selector: String?
        if let supplied = object["sessionID"] {
            guard let text = supplied as? String, let id = UUID(uuidString: text),
                model.tabs.contains(where: { $0.id == id })
            else { throw ExtensionPeerError.invalidRequest }
            selector = text
        }
        if operation == .create, model.tabs.count >= 32 { throw ExtensionPeerError.invalidRequest }
        var path: String?
        if operation == .switchWorktree {
            guard let text = object["worktreeID"] as? String, let id = UUID(uuidString: text),
                let selection = worktrees[id]
            else { throw ExtensionPeerError.invalidRequest }
            path = selection.1.path
        } else if object["worktreeID"] != nil {
            throw ExtensionPeerError.invalidRequest
        }
        let result = try await model.performSessionOperation(
            .init(operation: operation, session: selector, worktreePath: path))
        try Task.checkCancellation()
        guard !isStopped else { throw ExtensionPeerError.unavailable }
        return try JSONEncoder().encode(result)
    }
    func cancelPendingWork() async {
        await terminalSessions.stopAllAndWait()
        maintenance?.cancel()
        model.cancelDiscovery()
        await cliStreams?.stopAndWait()
    }

    func shutdown() async {
        guard !isStopped else { return }
        isStopped = true
        await terminalSessions.stopAllAndWait()
        await cliStreams?.stopAndWait()
        cliStreams = nil
        maintenance?.cancel()
        model.cancelDiscovery()
        model.stopAll()
        await model.shutdown()
        await QuinjetWorkOwnership.shutdown()
        await QuinjetMachines.shared.shutdown()
        await maintenance?.value
        maintenance = nil
        projects.removeAll()
        worktrees.removeAll()
        QuinjetPrivacy.shared.shutdown()
    }
}
