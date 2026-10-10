import EdithExtensionSupport
import EdithExtensionUI
import Foundation

struct QuinjetUIRemote: Codable {
    let machineID: UUID
    let machineName: String
    let target: String
    let platform: RemoteMachinePlatform
    let homeDirectory: String?
    let installed: Bool

    init(_ remote: QuinjetRemote) {
        machineID = remote.machineID
        machineName = remote.machineName
        target = remote.target
        platform = remote.platform
        homeDirectory = remote.homeDirectory
        installed = remote.executablePath != nil
    }

    var renderingValue: QuinjetRemote {
        .init(
            machineID: machineID, machineName: machineName, target: target, controlPath: "",
            platform: platform, homeDirectory: homeDirectory,
            executablePath: installed ? "available" : nil)
    }
}

struct QuinjetUITab: Codable {
    let id: UUID
    let projectName: String?
    let worktree: QuinjetWorktree?
    let remote: QuinjetUIRemote?
    let worktrees: [QuinjetWorktree]
    let machineID: UUID
    let errorMessage: String?
    let configuration: QuinjetLaunchConfiguration
    let externalLaunchMessage: String?
    let terminal: OwnedTerminalDescriptor?
}

struct QuinjetUIState: Codable {
    struct RemoteProjects: Codable {
        let machineID: UUID
        let projects: [QuinjetProject]
        let error: String?
    }
    struct MachineState: Codable {
        let id: UUID
        let state: String
        let failure: String?
    }
    let owner: String
    let generation: UUID
    let sequence: UInt64
    let tabs: [QuinjetUITab]
    let selected: UUID
    let projects: [QuinjetProject]
    let remoteProjects: [RemoteProjects]
    let themes: [String]
    let machines: [Machine]
    let machineStates: [MachineState]
    let usage: [String: Date]
    let hidesReview: Bool
    let cmuxAvailable: Bool
    let projectError: String?

    func validate() throws {
        guard owner == "quinjet", !tabs.isEmpty, tabs.count <= 32,
            Set(tabs.map(\.id)).count == tabs.count, tabs.contains(where: { $0.id == selected }),
            projects.count <= 1024, remoteProjects.count <= 1024, themes.count <= 256,
            Set(remoteProjects.map(\.machineID)).count == remoteProjects.count,
            Set(machineStates.map(\.id)).count == machineStates.count,
            projects.allSatisfy(Self.validProject),
            remoteProjects.allSatisfy({
                $0.projects.count <= 1024 && $0.projects.allSatisfy(Self.validProject)
            }),
            machines.count <= 1025, Set(machines.map(\.id)).count == machines.count,
            machines.contains(where: { $0.id == Machine.localID }),
            machineStates.count <= machines.count, usage.count <= 16384,
            themes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0) }),
            tabs.allSatisfy({ tab in
                tab.worktrees.allSatisfy(Self.validWorktree)
                    && (tab.worktree.map(Self.validWorktree) ?? true)
                    && tab.worktrees.count <= 1024
                    && machines.contains(where: { $0.id == tab.machineID })
                    && (tab.projectName?.utf8.count ?? 0) <= 1024
                    && (tab.errorMessage?.utf8.count ?? 0) <= 4096
                    && tab.terminal.map({ $0.handle.owner == owner }) ?? true
            })
        else { throw ExtensionPeerError.invalidRequest }
    }
    private static func validProject(_ project: QuinjetProject) -> Bool {
        project.name.utf8.count <= 1024 && project.commonDir.utf8.count <= 4096
            && !project.commonDir.utf8.contains(0) && project.worktrees.count <= 1024
            && project.worktrees.allSatisfy(validWorktree)
    }
    private static func validWorktree(_ worktree: QuinjetWorktree) -> Bool {
        QuinjetPath.isAbsolute(worktree.path) && worktree.path.utf8.count <= 4096
            && !worktree.path.utf8.contains(0) && worktree.head.utf8.count <= 256
            && (worktree.branch?.utf8.count ?? 0) <= 1024
            && (worktree.locked?.utf8.count ?? 0) <= 1024
            && (worktree.prunable?.utf8.count ?? 0) <= 1024
    }

}

@MainActor final class QuinjetUIClient {
    typealias Invoke = @MainActor (String, Data) async throws -> Data
    private let invoke: Invoke
    private let requests: OwnedEngineRequests
    private var pending: [UUID: Task<Data, Error>] = [:]
    private var stopped = false
    private var generation: UUID?
    private var sequence: UInt64 = 0

    init(invoke: @escaping Invoke) {
        let requests = OwnedEngineRequests(invoke: invoke)
        self.requests = requests
        self.invoke = { operation, payload in
            try await requests.perform(operation, payload: payload)
        }
    }
    convenience init(client: ExtensionEngineClient) {
        self.init { try await client.invoke($0, payload: $1) }
    }

    func state(_ operation: String, object: [String: Any] = [:]) async throws -> QuinjetUIState? {
        let data = try await request(operation, object: object)
        guard data.count <= 1_048_576 else { throw ExtensionPeerError.invalidRequest }
        let state = try JSONDecoder().decode(QuinjetUIState.self, from: data)
        try state.validate()
        guard generation == nil || generation == state.generation else {
            throw ExtensionPeerError.unavailable
        }
        generation = state.generation
        guard state.sequence > sequence else { return nil }
        sequence = state.sequence
        return state
    }

    func terminal(_ descriptor: OwnedTerminalDescriptor) throws -> OwnedTerminalClient {
        try OwnedTerminalClient(descriptor: descriptor, invoke: invoke)
    }

    func request(_ operation: String, object: [String: Any]) async throws -> Data {
        guard !stopped, pending.count < 520, operation.hasPrefix("quinjet.ui.") else {
            throw ExtensionPeerError.unavailable
        }
        try Task.checkCancellation()
        let payload = try JSONSerialization.data(withJSONObject: object)
        guard payload.count <= 16384 else { throw ExtensionPeerError.invalidRequest }
        let id = UUID()
        let task = Task { try await invoke(operation, payload) }
        pending[id] = task
        defer { pending[id] = nil }
        let data = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard !task.isCancelled else { throw CancellationError() }
        guard !stopped else { throw ExtensionPeerError.unavailable }
        return data
    }

    func cancel() {
        for task in pending.values { task.cancel() }
        pending.removeAll()
    }
    func stop() { stopped = true; requests.stop(); cancel() }
}

@MainActor final class QuinjetUIEngine {
    private let worker: QuinjetWorker
    private let generation = UUID()
    private var sequence: UInt64 = 0

    init(worker: QuinjetWorker) { self.worker = worker }

    func execute(_ operation: String, object: [String: Any]) async throws -> Data {
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        let model = worker.model
        switch operation {
        case "quinjet.ui.read":
            try keys(object, [])
        case "quinjet.ui.projects", "quinjet.ui.themes":
            guard Set(object.keys).isSubset(of: ["machineID"]) else {
                throw ExtensionPeerError.invalidRequest
            }
            if operation == "quinjet.ui.themes" {
                try keys(object, [])
                await model.refreshThemes()
            } else if let raw = object["machineID"] {
                guard let text = raw as? String, let id = UUID(uuidString: text),
                    let remote = model.tabs.first(where: { $0.remote?.machineID == id })?.remote
                else { throw ExtensionPeerError.invalidRequest }
                await model.refreshProjects(for: remote)
            } else {
                await model.refreshProjects()
            }
        case "quinjet.ui.machine":
            try keys(object, ["tabID", "machineID"])
            let tab = try tab(object)
            guard let text = object["machineID"] as? String, let id = UUID(uuidString: text),
                QuinjetMachines.shared.allMachines.contains(where: { $0.id == id })
            else { throw ExtensionPeerError.invalidRequest }
            tab.machineID = id
            tab.folderPicker = nil
            tab.remote = nil
            tab.errorMessage = nil
            if id != Machine.localID {
                do {
                    let remote = try await worker.resolveRemote(id)
                    try Task.checkCancellation()
                    guard !worker.isStopped, model.tabs.contains(where: { $0 === tab }),
                        tab.machineID == id
                    else { throw ExtensionPeerError.unavailable }
                    tab.remote = remote
                    await model.refreshProjects(for: remote)
                } catch is CancellationError { throw CancellationError() } catch {
                    tab.errorMessage = error.localizedDescription
                }
            }
        case "quinjet.ui.worktrees":
            try keys(object, ["tabID"])
            await model.presentWorktrees(for: try tab(object))
        case "quinjet.ui.open":
            try keys(object, ["tabID", "path", "configuration"])
            let tab = try tab(object)
            let path = try path(object)
            let configuration = try configuration(object)
            await model.openFolder(
                path, remote: tab.remote, in: tab,
                launchEnabled: worker.automaticActions, configuration: configuration)
        case "quinjet.ui.configuration":
            try keys(object, ["configuration"])
            model.apply(try configuration(object), launchEnabled: worker.automaticActions)
        case "quinjet.ui.session":
            guard Set(object.keys).isSubset(of: ["operation", "session", "worktreePath"]),
                object["operation"] != nil
            else { throw ExtensionPeerError.invalidRequest }
            let data = try JSONSerialization.data(withJSONObject: object)
            let request = try JSONDecoder().decode(QuinjetSessionRequest.self, from: data)
            _ = try await model.performSessionOperation(request)
        case "quinjet.ui.folder.home", "quinjet.ui.folder.list":
            try keys(object, operation.hasSuffix("home") ? ["tabID"] : ["tabID", "path"])
            let tab = try tab(object)
            guard tab.machineID == Machine.localID || tab.remote != nil else {
                throw ExtensionPeerError.unavailable
            }
            let session = QuinjetMachines.shared.session(for: tab.machineID)
            if operation.hasSuffix("home") {
                return try JSONEncoder().encode(await session.homeDirectory().get())
            }
            return try JSONEncoder().encode(await session.listFiles(path: path(object)).get())
        default: throw ExtensionPeerError.invalidRequest
        }
        try Task.checkCancellation()
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        return try snapshot()
    }

    private func snapshot() throws -> Data {
        sequence += 1
        let model = worker.model
        let machines = QuinjetMachines.shared.allMachines
        let state = QuinjetUIState(
            owner: "quinjet", generation: generation, sequence: sequence,
            tabs: model.tabs.map { tab in
                .init(
                    id: tab.id, projectName: tab.projectName, worktree: tab.worktree,
                    remote: tab.remote.map(QuinjetUIRemote.init), worktrees: tab.worktrees,
                    machineID: tab.machineID, errorMessage: tab.errorMessage,
                    configuration: tab.launchConfiguration,
                    externalLaunchMessage: tab.externalLaunchMessage,
                    terminal: tab.holder.descriptor)
            }, selected: model.selected, projects: model.projects,
            remoteProjects: model.uiRemoteProjects, themes: model.themes.map(\.rawValue),
            machines: machines,
            machineStates: machines.map { machine in
                let status = QuinjetMachines.shared.session(for: machine.id).state
                return .init(
                    id: machine.id,
                    state: status.isConnected
                        ? "connected"
                        : status.isBusy
                            ? "connecting"
                            : status.failureMessage == nil ? "disconnected" : "failed",
                    failure: status.failureMessage)
            }, usage: model.usage.snapshot, hidesReview: QuinjetPrivacy.shared.hidesReview,
            cmuxAvailable: QuinjetTerminal.cmux.isAvailable, projectError: model.projectError)
        try state.validate()
        let data = try JSONEncoder().encode(state)
        guard data.count <= 1_048_576 else { throw ExtensionPeerError.invalidRequest }
        return data
    }

    private func keys(_ object: [String: Any], _ keys: Set<String>) throws {
        guard Set(object.keys) == keys else { throw ExtensionPeerError.invalidRequest }
    }
    private func tab(_ object: [String: Any]) throws -> QuinjetTab {
        guard let text = object["tabID"] as? String, let id = UUID(uuidString: text),
            let tab = worker.model.tabs.first(where: { $0.id == id })
        else { throw ExtensionPeerError.invalidRequest }
        return tab
    }
    private func path(_ object: [String: Any]) throws -> String {
        guard let path = object["path"] as? String, QuinjetPath.isAbsolute(path),
            path.utf8.count <= 4096, !path.utf8.contains(0)
        else { throw ExtensionPeerError.invalidRequest }
        return path
    }
    private func configuration(_ object: [String: Any]) throws -> QuinjetLaunchConfiguration {
        guard let value = object["configuration"] as? [String: Any],
            Set(value.keys).isSubset(of: ["terminal", "theme", "appearance", "hostTheme"])
        else { throw ExtensionPeerError.invalidRequest }
        let config = try JSONDecoder().decode(
            QuinjetLaunchConfiguration.self,
            from: JSONSerialization.data(withJSONObject: value))
        guard config.terminal != .cmux || QuinjetTerminal.cmux.isAvailable,
            worker.model.themes.contains(config.theme), config.theme.rawValue.utf8.count <= 256
        else { throw ExtensionPeerError.invalidRequest }
        return config
    }
}
