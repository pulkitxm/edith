import EdithExtensionSupport
import Foundation

@MainActor final class MachineUIEngine {
    typealias Session = (UUID) throws -> MachineSession
    private let session: Session
    private let state: () -> MachineUIState
    private let mutation: (MachineUIMutation) async throws -> Void
    private let observe: (UUID, Bool) -> Void
    private let workspace: (WorkspaceStore) throws -> Void
    private var stopped = false
    private struct Job {
        var task: Task<Void, Never>
        var touched: Date
        var reply: MachineUIReply?
    }
    private var jobs: [UUID: Job] = [:]
    private var retired: [Task<Void, Never>] = []
    private var reaper: Task<Void, Never>?

    init(
        session: @escaping Session, state: @escaping () -> MachineUIState,
        mutation: @escaping (MachineUIMutation) async throws -> Void,
        workspace: @escaping (WorkspaceStore) throws -> Void,
        observe: @escaping (UUID, Bool) -> Void = { _, _ in }
    ) {
        self.session = session
        self.state = state
        self.mutation = mutation
        self.workspace = workspace
        self.observe = observe
    }

    func stop() {
        stopped = true
        reaper?.cancel(); reaper = nil
        for job in jobs.values { job.task.cancel(); retired.append(job.task) }
        jobs = [:]
    }

    func shutdown() async {
        stop()
        let retained = retired
        retired = []
        for task in retained { await task.value }
    }

    private func begin(_ value: MachineUIJobInput) throws -> UUID {
        guard
            ["machines.ui.action", "machines.ui.probe", "machines.ui.files", "machines.ui.preview"]
                .contains(value.operation),
            value.payload.count <= 2_097_152, jobs.count < 4
        else { throw MachineUIError.invalidRequest }
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            let reply: MachineUIReply
            do {
                let data = try await executeValidated(value.operation, payload: value.payload)
                try Task.checkCancellation()
                reply = MachineUIReply(value: data, error: nil)
            } catch {
                reply = MachineUIReply(
                    value: nil, error: String(error.localizedDescription.prefix(4_096)))
            }
            guard !stopped, jobs[id] != nil else { return }
            jobs[id]?.reply = reply
        }
        jobs[id] = Job(task: task, touched: Date())
        if reaper == nil {
            reaper = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self, !stopped else { return }
                    let expired = jobs.filter { Date().timeIntervalSince($0.value.touched) > 10 }
                        .map(\.key)
                    for id in expired { cancelJob(id) }
                    let completed = retired
                    retired = []
                    for task in completed { await task.value }
                }
            }
        }
        return id
    }

    private func cancelJob(_ id: UUID) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        job.task.cancel()
        retired.append(job.task)
    }

    func execute(_ operation: String, payload: Data) async throws -> Data {
        do {
            let value = try await executeValidated(operation, payload: payload)
            return try JSONEncoder().encode(MachineUIReply(value: value, error: nil))
        } catch is CancellationError { throw CancellationError() } catch {
            return try JSONEncoder().encode(
                MachineUIReply(value: nil, error: String(error.localizedDescription.prefix(4_096))))
        }
    }

    private func executeValidated(_ operation: String, payload: Data) async throws -> Data {
        guard !stopped, payload.count <= 2_097_152 else { throw MachineUIError.unavailable }
        switch operation {
        case "machines.ui.begin":
            return try encode(begin(JSONDecoder().decode(MachineUIJobInput.self, from: payload)))
        case "machines.ui.poll":
            let value = try JSONDecoder().decode(MachineUIJobPoll.self, from: payload)
            guard var job = jobs[value.id] else { throw MachineUIError.unavailable }
            job.touched = Date()
            jobs[value.id] = job
            let reply = job.reply
            if value.consume, reply != nil { jobs.removeValue(forKey: value.id) }
            return try encode(MachineUIJobState(complete: reply != nil, reply: reply))
        case "machines.ui.cancel":
            let id = try JSONDecoder().decode(UUID.self, from: payload)
            cancelJob(id)
            return try encode(true)
        case "machines.ui.configuration":
            guard let value = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                value.isEmpty
            else { throw MachineUIError.invalidRequest }
            return try encode(
                MachineUIConfigurationState(
                    hosts: SSHConfigFile.concreteHosts(),
                    sudoPasswordStored: Set(
                        state().machines.filter { SudoPassword.isStored(machineID: $0.id) }.map(
                            \.id))))
        case "machines.ui.probe":
            let value = try JSONDecoder().decode(MachineUIMutation.self, from: payload)
            guard MachineConnectionRecipe.valid(value.machine),
                value.secrets.login.map({ $0.utf8.count <= 4_096 }) ?? true
            else { throw MachineUIError.invalidRequest }
            let connection = SSHConnection(machine: value.machine)
            if let secret = value.secrets.login {
                MachineSecrets.set(
                    secret, machineID: value.machine.id,
                    kind: value.machine.auth == .password ? .password : .passphrase)
            }
            do {
                try await connection.connect()
                let platform = await connection.remotePlatform ?? .linux
                let result = try await connection.run(
                    MachineConnectionProbe.command(platform: platform), timeout: 20)
                await connection.disconnect()
                if !result.succeeded {
                    throw MachineUIFailure(
                        message: result.stderrText.isEmpty
                            ? "The connection probe failed." : result.stderrText)
                }
                return try encode(result.stdoutText)
            } catch { await connection.disconnect(); throw error }
        case "machines.ui.state":
            guard let value = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                value.isEmpty
            else { throw MachineUIError.invalidRequest }
            return try encode(state())
        case "machines.ui.mutate":
            let value = try JSONDecoder().decode(MachineUIMutation.self, from: payload)
            guard MachineConnectionRecipe.valid(value.machine),
                value.machine.id != Machine.localID,
                value.secrets.login.map({ $0.utf8.count <= 4_096 }) ?? true,
                value.secrets.sudoPassword.map({ $0.utf8.count <= 4_096 }) ?? true
            else { throw MachineUIError.invalidRequest }
            try await mutation(value)
            try Task.checkCancellation()
            return try encode(state())
        case "machines.ui.workspace":
            let value = try JSONDecoder().decode(WorkspaceStore.self, from: payload)
            guard value.layouts.count <= 128,
                value.layouts.allSatisfy({ $0.paneCount <= 64 && $0.name.utf8.count <= 256 })
            else { throw MachineUIError.invalidRequest }
            try workspace(value)
            return try encode(value)
        case "machines.ui.action":
            let value = try JSONDecoder().decode(MachineUIAction.self, from: payload)
            try value.validate()
            let session = try session(value.machineID)
            let result: Data
            switch value.operation {
            case .connect: session.start(); result = try encode(true)
            case .disconnect: await session.shutdown(); result = try encode(true)
            case .retry: session.retry(); result = try encode(true)
            case .observe:
                observe(session.id, value.active)
                session.setForegroundObservation(value.token!, active: value.active)
                result = try encode(true)
            case .dockerObserve:
                if value.active {
                    session.beginDockerObservation()
                } else {
                    session.endDockerObservation()
                }
                result = try encode(true)
            case .speedObserve:
                if value.active {
                    session.beginInternetSpeedObservation()
                } else {
                    session.endInternetSpeedObservation()
                }
                result = try encode(true)
            case .forwardAdd, .forwardRemove:
                guard let forward = value.forward, forward.machineID == session.id else {
                    throw MachineUIError.invalidRequest
                }
                result = try encode(
                    try await MachineForwardOperationExecution.perform(
                        value.operation == .forwardAdd ? .add : .remove, forward: forward,
                        existing: state().forwards,
                        setActive: { forward, active in
                            await session.setForward(forward, active: active)
                        }
                    ).get())
            case .snippetAdd, .snippetRemove:
                guard let snippet = value.snippet,
                    snippet.machineID == nil || snippet.machineID == session.id,
                    snippet.command.utf8.count <= 32_768, snippet.title.utf8.count <= 256
                else { throw MachineUIError.invalidRequest }
                result = try encode(
                    try MachineSnippetOperationExecution.perform(
                        value.operation == .snippetAdd ? .add : .remove, snippet: snippet
                    ).get())
            case .power:
                guard let operation = MachinePowerOperation(rawValue: value.text) else {
                    throw MachineUIError.invalidRequest
                }
                result = try encode(
                    try await MachinePowerOperationExecution.perform(
                        operation, machine: session.machine,
                        learnedMACAddress: session.facts.macAddress,
                        platform: session.remotePlatform ?? .linux,
                        run: { command, input, timeout in
                            await session.runCommand(command, stdin: input, timeout: timeout)
                        }
                    ).get())
            case .mount, .unmount:
                result = try encode(
                    try await MachineMountOperationExecution.perform(
                        value.operation == .mount ? .mount : .unmount, machine: session.machine
                    ).get())
            case .command:
                result = try encode(
                    try await session.runCommand(
                        value.text, stdin: value.input, timeout: value.timeout
                    ).get())
            case .docker:
                result = try encode(
                    try await session.runDocker(value.text, timeout: value.timeout).get())
            case .refreshDocker: session.refreshDockerNow(); result = try encode(true)
            case .refreshInventory:
                await session.refreshImagesAndVolumes(); result = try encode(true)
            case .refreshServices: await session.refreshServices(); result = try encode(true)
            case .refreshProfile: await session.refreshPlatformProfile(); result = try encode(true)
            case .setProfile:
                guard let duration = MachineProfileDuration(rawValue: value.duration) else {
                    throw MachineUIError.invalidRequest
                }
                result = try encode(
                    try await session.setPlatformProfile(value.text, duration: duration).get())
            case .speedTest: session.refreshInternetSpeed(); result = try encode(true)
            case .restoreMount: result = try encode(await session.restoreMount())
            case .forward:
                guard let forward = value.forward,
                    state().forwards.contains(where: { $0 == forward })
                else { throw MachineUIError.invalidRequest }
                result = try encode(await session.setForward(forward, active: value.active))
            case .listFiles:
                result = try encode(try await session.listFiles(path: value.text).get())
            case .home: result = try encode(try await session.homeDirectory().get())
            case .mkdir:
                result = try encode(try await session.createDirectory(path: value.text).get())
            }
            try Task.checkCancellation()
            guard !stopped else { throw MachineUIError.unavailable }
            return result
        default: throw MachineUIError.invalidRequest
        }
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 6_291_456 else { throw MachineUIError.invalidRequest }
        return data
    }
}
