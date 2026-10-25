import EdithExtensionSupport
import Foundation

@MainActor public final class MachineUIClient: FinderBridgeTransport {
    fileprivate let client: ExtensionEngineClient
    let terminalUI: MachineTerminalUIPresentation
    private var generation = 0
    private var stopped = false
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var polling: Task<Void, Never>?
    private var requests: [UUID: Task<Data, Error>] = [:]
    private var operations: [UUID: Task<Void, Never>] = [:]
    private var operationCancellation: [UUID: @MainActor () -> Void] = [:]
    var receive: (MachineUIState) -> Void = { _ in }
    var failure: (String) -> Void = { _ in }

    public init(client: ExtensionEngineClient) {
        self.client = client
        terminalUI = MachineTerminalUIPresentation(presentationID: client.presentationID)
    }

    func start() {
        guard polling == nil, !stopped else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do { try await refresh() } catch {
                    guard !Task.isCancelled, !stopped else { return }
                    failure(error.localizedDescription)
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func cancelPendingWork() {
        guard !stopped else { return }
        stopped = true
        generation += 1
        polling?.cancel()
        for task in tasks.values { task.cancel() }
        for task in requests.values { task.cancel() }
        for cancel in operationCancellation.values { cancel() }
    }

    func drain() async {
        cancelPendingWork()
        let queued = Array(tasks.values)
        let running = Array(operations.values)
        let pending = Array(requests.values)
        await polling?.value
        for task in queued { await task.value }
        for task in running { await task.value }
        for task in pending { _ = await task.result }
    }

    public func shutdown() {
        cancelPendingWork()
        terminalUI.invalidate()
        client.invalidate()
    }

    fileprivate func owned<Value>(_ work: @escaping @MainActor () async throws -> Value)
        async throws
        -> Value
    {
        guard !stopped else { throw MachineUIError.unavailable }
        let id = UUID()
        let task = Task { try await work() }
        operationCancellation[id] = { task.cancel() }
        operations[id] = Task { [self, task] in
            _ = await task.result
            operationCancellation[id] = nil
            operations[id] = nil
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    fileprivate func cleanup<Request: Encodable>(_ operation: String, value: Request) async {
        let id = UUID()
        let task = Task { [self] in
            let _: Bool? = try? await request(operation, value: value, draining: true)
        }
        tasks[id] = task
        await task.value
        tasks[id] = nil
    }

    func refresh() async throws {
        let state: MachineUIState = try await request(
            "machines.ui.state", value: [String: String]())
        guard state.machines.count <= 1_024, state.sessions.count <= 1_025,
            Set(state.machines.map(\.id)).count == state.machines.count,
            Set(state.sessions.map { $0.machine.id }).count == state.sessions.count,
            state.sessions.allSatisfy({
                $0.histories.count == 8 && $0.histories.allSatisfy { $0.count <= 60 }
            })
        else { throw MachineUIError.invalidRequest }
        receive(state)
        let _: Bool = try await request(
            "machines.ui.heartbeat", value: MachineUIPresentation(id: client.presentationID))
        _ = try await terminal(
            MachineTerminalRequest(operation: .heartbeat, machineID: Machine.localID))
    }

    public func action<Value: Decodable>(_ value: MachineUIAction) async throws -> Value {
        var value = value
        value.presentationID = client.presentationID
        try value.validate()
        return try await job("machines.ui.action", value: value)
    }

    func mutate(_ value: MachineUIMutation) async throws {
        let state: MachineUIState = try await request("machines.ui.mutate", value: value)
        receive(state)
    }

    func openWindow(_ value: MachineHostWindowRequest) async throws {
        var value = value; value.presentationID = client.presentationID
        try value.validate()
        let _: Bool = try await job("machines.ui.openWindow", value: value)
    }

    func logs(_ value: MachineLogRequest) async throws -> MachineLogFrame {
        var value = value; value.presentationID = client.presentationID
        try value.validate()
        return try await request("machines.ui.logs", value: value)
    }

    func terminal(_ value: MachineTerminalRequest) async throws -> MachineTerminalFrame {
        var value = value
        value.presentationID = client.presentationID
        try value.validate()
        let frame: MachineTerminalFrame
        if [.upload, .dropPaths, .dropFinish].contains(value.operation) {
            frame = try await job("machines.ui.terminal", value: value)
        } else {
            frame = try await request("machines.ui.terminal", value: value)
        }
        guard frame.bytes.count <= 32_768, frame.paths.count <= 128,
            frame.link.map({ $0.count <= 16_384 }) ?? true,
            frame.paths.allSatisfy({ $0.utf8.count <= 4096 && !$0.utf8.contains(0) }),
            frame.shells.count <= WindowsTerminalShell.allCases.count + 1
        else { throw MachineUIError.invalidRequest }
        if value.operation == .read {
            guard frame.handle == value.handle, frame.nextOffset >= value.offset,
                frame.nextOffset - value.offset == UInt64(frame.bytes.count)
            else { throw MachineUIError.stale }
        }
        return frame
    }

    func configuration() async throws -> MachineUIConfigurationState {
        try await request("machines.ui.configuration", value: [String: String]())
    }

    func probe(_ machine: Machine, secrets: MachineSecretChanges) async throws -> String {
        try await job(
            "machines.ui.probe",
            value: MachineUIMutation(operation: .add, machine: machine, secrets: secrets))
    }

    private var paneSequence: UInt64 = 0

    func workspacePane(
        baseline: WorkspaceLayout, paneID: UUID, tabID: UUID, terminal: MachineTerminalRequest,
        action: MachineWorkspacePaneRequest.Action, side: InsertSide? = nil,
        distance: Double? = nil, extent: Double? = nil
    ) async throws -> WorkspaceStore {
        guard paneSequence < UInt64.max, terminalUI.isAvailable else {
            throw MachineUIError.unavailable
        }
        paneSequence += 1
        var terminal = terminal; terminal.presentationID = client.presentationID
        return try await request(
            "machines.ui.workspace.pane",
            value: MachineWorkspacePaneRequest(
                presentationID: client.presentationID, terminal: terminal, sequence: paneSequence,
                baseline: baseline, paneID: paneID, tabID: tabID, action: action, side: side,
                distance: distance, extent: extent))
    }

    func workspace(_ value: WorkspaceStore) async throws -> WorkspaceStore {
        try await request("machines.ui.workspace", value: value)
    }

    public func enqueue(_ value: MachineUIAction) {
        enqueue {
            let _: Bool = try await self.action(value)
        }
    }

    func enqueue(_ work: @escaping @MainActor () async throws -> Void) {
        guard !stopped else { return }
        let id = UUID()
        tasks[id] = Task { [weak self] in
            do { try await work() } catch {
                if !Task.isCancelled, let self, !stopped { failure(error.localizedDescription) }
            }
            self?.tasks.removeValue(forKey: id)
        }
    }

    fileprivate func job<Request: Encodable, Reply: Decodable>(
        _ operation: String, value: Request,
        progress: @escaping (FileOperationProgress?) -> Void = { _ in }
    ) async throws -> Reply {
        try await owned { [self] in
            try await jobOwned(operation, value: value, progress: progress)
        }
    }

    private func jobOwned<Request: Encodable, Reply: Decodable>(
        _ operation: String, value: Request, progress: @escaping (FileOperationProgress?) -> Void
    ) async throws -> Reply {
        let id: UUID = try await request(
            "machines.ui.begin",
            value: MachineUIJobInput(
                presentationID: client.presentationID, operation: operation,
                payload: JSONEncoder().encode(value)))
        do {
            while true {
                try Task.checkCancellation()
                let state: MachineUIJobState = try await request(
                    "machines.ui.poll", value: MachineUIJobPoll(id: id, consume: true))
                if let value = state.progress {
                    guard value.total >= 0, value.completed >= 0, value.title.utf8.count <= 4096,
                        value.bytesTransferred >= 0
                    else { throw MachineUIError.invalidRequest }
                }
                progress(state.progress)
                if state.complete {
                    guard let reply = state.reply else { throw MachineUIError.invalidRequest }
                    if let error = reply.error { throw MachineUIFailure(message: error) }
                    guard let data = reply.value else { throw MachineUIError.invalidRequest }
                    return try JSONDecoder().decode(Reply.self, from: data)
                }
                try await Task.sleep(for: .milliseconds(200))
            }
        } catch {
            if Task.isCancelled { await cleanup("machines.ui.cancel", value: id) }
            throw error
        }
    }

    fileprivate func request<Request: Encodable, Reply: Decodable>(
        _ operation: String, value: Request, draining: Bool = false
    ) async throws -> Reply {
        guard !stopped || draining else { throw MachineUIError.unavailable }
        let generation = generation
        let payload = try JSONEncoder().encode(value)
        let id = UUID()
        let task = Task { [client] in try await client.invoke(operation, payload: payload) }
        requests[id] = task
        defer { requests[id] = nil }
        let bytes = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard draining || (!stopped && generation == self.generation) else {
            throw MachineUIError.stale
        }
        let reply = try JSONDecoder().decode(MachineUIReply.self, from: bytes)
        if let error = reply.error { throw MachineUIFailure(message: error) }
        guard let value = reply.value, value.count <= 6_291_456 else {
            throw MachineUIError.invalidRequest
        }
        return try JSONDecoder().decode(Reply.self, from: value)
    }
}

struct MachineTerminalUIEvent: Codable {
    enum Action: String, Codable {
        case fontZoomIn, fontZoomOut, fontZoomReset
        case newTab, closeTab, nextTab, previousTab, windowClosed
    }
    let version: Int
    let presentationID: UUID
    let sequence: UInt64
    let active: Bool
    let key: Bool
    let visible: Bool
    let action: Action?
}

@MainActor final class MachineTerminalUIPresentation {
    private struct Entry { weak var holder: TerminalSessionHolder? }
    let presentationID: UUID
    private var holders: [UUID: Entry] = [:]
    private var latest: MachineTerminalUIEvent?
    private var invalidated = false

    init(presentationID: UUID) { self.presentationID = presentationID }

    var isAvailable: Bool { !invalidated }

    var focused: Bool {
        guard !invalidated, let latest, latest.active, latest.key, latest.visible else {
            return false
        }
        return focusedHolders.count == 1
    }

    func register(_ holder: TerminalSessionHolder) {
        guard !invalidated else { return }
        holders = holders.filter { $0.value.holder != nil }
        guard holders[holder.id] != nil || holders.count < 64 else { return }
        holders[holder.id] = Entry(holder: holder)
        update(holder)
    }

    func unregister(_ holder: TerminalSessionHolder) { holders.removeValue(forKey: holder.id) }

    func update(_ holder: TerminalSessionHolder) {
        guard holders[holder.id]?.holder === holder else { return }
        holder.ghosttyView?.setHostWindowState(
            active: !invalidated && latest?.active == true && latest?.visible == true
                && holder.presented,
            key: !invalidated && latest?.key == true && latest?.visible == true && holder.presented)
    }

    func accept(_ data: Data) throws -> Bool {
        guard !invalidated, data.count <= 1_024 else { throw MachineUIError.invalidRequest }
        let event = try JSONDecoder().decode(MachineTerminalUIEvent.self, from: data)
        guard event.version == 1, event.presentationID == presentationID,
            latest.map({ event.sequence > $0.sequence }) ?? true
        else { throw MachineUIError.invalidRequest }
        latest = event
        for holder in holders.values.compactMap({ $0.holder }) { update(holder) }
        guard let action = event.action else { return true }
        if action == .windowClosed { invalidate(); return true }
        guard event.active, event.key, event.visible, focusedHolders.count == 1,
            let holder = focusedHolders.first
        else { return false }
        switch action {
        case .fontZoomIn: return holder.ghosttyView?.fontZoom(.increase) ?? false
        case .fontZoomOut: return holder.ghosttyView?.fontZoom(.decrease) ?? false
        case .fontZoomReset: return holder.ghosttyView?.fontZoom(.reset) ?? false
        case .newTab, .closeTab, .nextTab, .previousTab:
            return holder.hostTabAction?(action) ?? false
        case .windowClosed: return false
        }
    }

    func admitsPaneAction(_ holder: TerminalSessionHolder, eventSequence: UInt64? = nil) -> Bool {
        guard holders[holder.id]?.holder === holder, focused,
            eventSequence.map({ $0 == latest?.sequence }) ?? true
        else { return false }
        return focusedHolders.first === holder
    }

    var eventSequence: UInt64? { latest?.sequence }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        let owned = holders.values.compactMap { $0.holder }
        holders = [:]
        for holder in owned { holder.stop() }
    }

    private var focusedHolders: [TerminalSessionHolder] {
        holders.values.compactMap { $0.holder }.filter {
            $0.started && $0.presented && $0.ghosttyView?.hasInputFocus == true
        }
    }
}

extension MachineUIClient {
    public var bridgePresentationID: UUID { client.presentationID }
    public var filesOperation: String { "machines.ui.files" }
    public var previewOperation: String { "machines.ui.preview" }
    public var exportOperation: String { "machines.ui.export" }

    public func bridgeOwned<Value>(_ work: @escaping @MainActor () async throws -> Value)
        async throws -> Value
    {
        try await owned(work)
    }

    public func bridgeJob<Request: Encodable, Reply: Decodable>(
        _ operation: String, value: Request, progress: @escaping (FileOperationProgress?) -> Void
    ) async throws -> Reply {
        try await job(operation, value: value, progress: progress)
    }

    public func bridgeRequest<Request: Encodable, Reply: Decodable>(
        _ operation: String, value: Request
    ) async throws -> Reply {
        try await request(operation, value: value)
    }

    public func bridgeCleanup<Request: Encodable>(_ operation: String, value: Request) async {
        await cleanup(operation, value: value)
    }
}
