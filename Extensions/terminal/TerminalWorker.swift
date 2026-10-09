import EdithExtensionSupport
import Foundation
import GhosttyTerminal

@MainActor final class TerminalWorker {
    let model: TerminalTabsModel
    private let showWindow: @MainActor () -> Void
    private let shutdownEngine: @MainActor () -> Void
    private(set) var isStopped = false

    init(
        model: TerminalTabsModel? = nil,
        showWindow: @escaping @MainActor () -> Void = {},
        shutdownEngine: @escaping @MainActor () -> Void = { GhosttyRuntime.shared.shutdown() }
    ) {
        self.model = model ?? TerminalTabsModel()
        self.showWindow = showWindow
        self.shutdownEngine = shutdownEngine
    }

    struct Status: Codable, Equatable {
        let sessions: Int
        let running: Int
        let broadcast: Bool
    }

    struct Session: Codable, Equatable {
        let id: String
        let title: String
        let running: Bool
        let selected: Bool
    }

    struct OpenResult: Codable, Equatable {
        let opened: Bool
        let id: String?
    }

    struct BroadcastRequest: Codable {
        let command: String
    }

    struct BroadcastResult: Codable, Equatable {
        let sent: Int
        let unavailable: Int
    }

    struct SessionRequest: Codable {
        let id: String
    }

    static let commands: Set<String> = [
        "terminal.status", "terminal.sessions", "terminal.open", "terminal.broadcast",
        "terminal.select",
    ]

    var status: Status {
        Status(
            sessions: model.tabs.count, running: model.tabs.filter(\.holder.started).count,
            broadcast: model.broadcast)
    }

    var sessions: [Session] {
        model.tabs.map {
            Session(
                id: $0.id.uuidString, title: Self.bounded($0.displayTitle, bytes: 512),
                running: $0.holder.started, selected: $0.id == model.selected)
        }
    }

    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !isStopped, Self.commands.contains(command), payload.count <= 8_192 else {
            throw ExtensionPeerError.invalidRequest
        }
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        switch command {
        case "terminal.status":
            try Self.requireEmpty(payload)
            return try encoder.encode(status)
        case "terminal.sessions":
            try Self.requireEmpty(payload)
            return try encoder.encode(sessions)
        case "terminal.open":
            try Self.requireEmpty(payload)
            let tab = openTab()
            return try encoder.encode(OpenResult(opened: tab != nil, id: tab?.id.uuidString))
        case "terminal.select":
            let request = try JSONDecoder().decode(SessionRequest.self, from: payload)
            guard let id = UUID(uuidString: request.id), model.tabs.contains(where: { $0.id == id })
            else { throw ExtensionPeerError.invalidRequest }
            focus(id)
            return try encoder.encode(sessions)
        default:
            let request = try JSONDecoder().decode(BroadcastRequest.self, from: payload)
            guard case let .success(plan) = TerminalBroadcastPlan.make(command: request.command)
            else { throw ExtensionPeerError.invalidRequest }
            try Task.checkCancellation()
            guard !isStopped else { throw ExtensionPeerError.unavailable }
            let delivery = model.sendBroadcast(plan)
            return try encoder.encode(
                BroadcastResult(sent: delivery.sent, unavailable: delivery.unavailable))
        }
    }

    @discardableResult
    func openTab() -> TerminalTabsModel.Tab? {
        guard !isStopped else { return nil }
        let tab = model.addTab()
        showWindow()
        return tab
    }

    func focus(_ id: UUID) {
        guard !isStopped else { return }
        model.select(id)
        showWindow()
    }

    func windowClosed() {
        model.stopAll()
    }

    func shutdown() {
        guard !isStopped else { return }
        isStopped = true
        model.stopAll()
        shutdownEngine()
    }

    private static func requireEmpty(_ payload: Data) throws {
        guard payload.isEmpty || payload == Data("{}".utf8) else {
            throw ExtensionPeerError.invalidRequest
        }
    }

    static func bounded(_ value: String, bytes: Int) -> String {
        var result = ""
        var count = 0
        for scalar in value.unicodeScalars where scalar.value != 0 {
            let size = String(scalar).utf8.count
            guard count + size <= bytes else { break }
            result.unicodeScalars.append(scalar)
            count += size
        }
        return result
    }
}
