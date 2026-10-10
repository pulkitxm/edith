import EdithExtensionSupport
import Foundation

@MainActor final class TerminalEngine {
    struct Session: Codable, Equatable, Identifiable {
        let id: UUID
        let generation: UUID
        let title: String
        let directory: String
        let running: Bool
        let exitCode: Int32?
        let error: String?
        let selected: Bool
    }

    struct Snapshot: Codable, Equatable {
        let sessions: [Session]
        let broadcast: Bool
    }

    struct SessionRequest: Codable {
        let id: UUID
        let generation: UUID
    }

    struct InputRequest: Codable {
        let session: SessionRequest
        let bytes: Data
    }

    struct ReadRequest: Codable {
        let session: SessionRequest
        let offset: UInt64
    }

    struct ResizeRequest: Codable {
        let session: SessionRequest
        let columns: UInt16
        let rows: UInt16
    }

    struct PresentationRequest: Codable {
        let session: SessionRequest
        let title: String
        let directory: String
    }

    private struct Tab {
        let id: UUID
        let generation: UUID
        var title: String
        var directory: String
        let terminal: TerminalPTY
    }

    static let commands: Set<String> = [
        "terminal.snapshot", "terminal.open", "terminal.select", "terminal.close",
        "terminal.restart", "terminal.input", "terminal.read", "terminal.resize",
        "terminal.presentation", "terminal.broadcast", "terminal.preferences",
        "terminal.savePreferences",
    ]

    private var tabs: [Tab] = []
    private var selected: UUID?
    private var polling: Task<Void, Never>?
    private var failures: [UUID: any Error] = [:]
    private var nextNumber = 1
    private let launch: @MainActor () -> TerminalLaunch
    private let defaults: UserDefaults
    private(set) var isStopped = false
    var broadcast = false

    init(
        defaults: UserDefaults = SharedDefaults.store,
        launch: (@MainActor () -> TerminalLaunch)? = nil
    ) {
        self.defaults = defaults
        self.launch = launch ?? { TerminalLaunchPlan.make(settings: .load(defaults)) }
    }

    func snapshot() throws -> Snapshot {
        guard !isStopped else { throw ExtensionPeerError.unavailable }
        let sessions = tabs.map { tab in
            if failures[tab.id] == nil {
                do { try tab.terminal.poll() } catch { failures[tab.id] = error }
            }
            return Session(
                id: tab.id, generation: tab.generation, title: tab.title,
                directory: tab.directory,
                running: tab.terminal.exitCode == nil && failures[tab.id] == nil,
                exitCode: tab.terminal.exitCode,
                error: failures[tab.id] == nil ? nil : "The owned terminal stream failed.",
                selected: tab.id == selected)
        }
        return Snapshot(sessions: sessions, broadcast: broadcast)
    }

    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !isStopped, Self.commands.contains(command), payload.count <= 32_768 else {
            throw ExtensionPeerError.invalidRequest
        }
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let decoder = JSONDecoder()
        switch command {
        case "terminal.preferences":
            try requireEmpty(payload)
            return try encoder.encode(TerminalSettings.load(defaults))
        case "terminal.savePreferences":
            let settings = try decoder.decode(TerminalSettings.self, from: payload)
            try settings.save(to: defaults)
            return try encoder.encode(TerminalSettings.load(defaults))
        case "terminal.snapshot":
            try requireEmpty(payload)
        case "terminal.open":
            try requireEmpty(payload)
            try open()
        case "terminal.select":
            let request = try decoder.decode(SessionRequest.self, from: payload)
            selected = try tab(request, allowFailed: true).id
        case "terminal.close":
            let request = try decoder.decode(SessionRequest.self, from: payload)
            let owned = try tab(request, allowFailed: true)
            owned.terminal.close()
            tabs.removeAll { $0.id == owned.id }
            failures[owned.id] = nil
            if selected == owned.id { selected = tabs.last?.id }
        case "terminal.restart":
            let request = try decoder.decode(SessionRequest.self, from: payload)
            let previous = try tab(request, allowFailed: true)
            let plan = launch()
            let replacement = try TerminalPTY(launch: plan)
            previous.terminal.close()
            guard let index = tabs.firstIndex(where: { $0.id == previous.id }) else {
                replacement.close()
                throw ExtensionPeerError.unavailable
            }
            failures[previous.id] = nil
            tabs[index] = Tab(
                id: previous.id, generation: UUID(), title: previous.title,
                directory: plan.currentDirectory, terminal: replacement)
        case "terminal.input":
            let request = try decoder.decode(InputRequest.self, from: payload)
            try tab(request.session).terminal.send(request.bytes)
        case "terminal.resize":
            let request = try decoder.decode(ResizeRequest.self, from: payload)
            try tab(request.session).terminal.resize(columns: request.columns, rows: request.rows)
        case "terminal.read":
            let request = try decoder.decode(ReadRequest.self, from: payload)
            return try encoder.encode(try await read(request))
        case "terminal.presentation":
            let request = try decoder.decode(PresentationRequest.self, from: payload)
            _ = try tab(request.session)
            guard request.title.utf8.count <= 512, request.directory.utf8.count <= 4_096,
                !request.title.utf8.contains(0), !request.directory.utf8.contains(0),
                let index = tabs.firstIndex(where: { $0.id == request.session.id })
            else { throw ExtensionPeerError.invalidRequest }
            tabs[index].title = request.title
            tabs[index].directory = request.directory
        case "terminal.broadcast":
            let request = try decoder.decode(TerminalWorker.BroadcastRequest.self, from: payload)
            guard case let .success(plan) = TerminalBroadcastPlan.make(command: request.command)
            else { throw ExtensionPeerError.invalidRequest }
            var sent = 0
            var unavailable = 0
            for owned in tabs {
                _ = try owned.terminal.read(after: owned.terminal.offset)
                guard owned.terminal.exitCode == nil else { unavailable += 1; continue }
                do {
                    try owned.terminal.send(Data(plan.terminalInput.utf8))
                    sent += 1
                } catch { unavailable += 1 }
            }
            return try encoder.encode(
                TerminalWorker.BroadcastResult(sent: sent, unavailable: unavailable))
        default: throw ExtensionPeerError.invalidRequest
        }
        return try encoder.encode(snapshot())
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        polling?.cancel()
        polling = nil
        failures.removeAll()
        for tab in tabs { tab.terminal.close() }
        tabs.removeAll()
        selected = nil
    }

    private func open() throws {
        guard tabs.count < TerminalTabsModel.maximumTabs else {
            throw ExtensionPeerError.rejected("The terminal tab limit has been reached.")
        }
        let plan = launch()
        let owned = Tab(
            id: UUID(), generation: UUID(), title: "Shell \(nextNumber)",
            directory: plan.currentDirectory, terminal: try TerminalPTY(launch: plan))
        nextNumber += 1
        tabs.append(owned)
        selected = owned.id
        startPolling()
    }

    private func tab(_ request: SessionRequest, allowFailed: Bool = false) throws -> Tab {
        guard !isStopped,
            let tab = tabs.first(where: {
                $0.id == request.id && $0.generation == request.generation
            })
        else { throw ExtensionPeerError.invalidRequest }
        if !allowFailed, let failure = failures[tab.id] { throw failure }
        return tab
    }

    private func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                guard let self, !self.isStopped else { return }
                guard !self.tabs.isEmpty else { self.polling = nil; return }
                for tab in self.tabs where self.failures[tab.id] == nil {
                    do { try tab.terminal.poll() } catch { self.failures[tab.id] = error }
                }
            }
        }
    }

    private func read(_ request: ReadRequest) async throws -> TerminalPTY.Output {
        for _ in 0..<25 {
            try Task.checkCancellation()
            let output = try tab(request.session).terminal.read(after: request.offset)
            if !output.bytes.isEmpty || output.exitCode != nil { return output }
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        return try tab(request.session).terminal.read(after: request.offset)
    }

    private func requireEmpty(_ payload: Data) throws {
        guard payload.isEmpty || payload == Data("{}".utf8) else {
            throw ExtensionPeerError.invalidRequest
        }
    }
}
