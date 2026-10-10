import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import UserNotifications

struct UsageUILimitsSummary: Codable, Sendable {
    let providers: [LimitProvider: LimitsHistory.Latest]
    let current: LimitsTopicSnapshot?
}

struct UsageUILimits: Codable, Sendable {
    let providers: [LimitProvider: LimitsHistory.Latest]
    let points: [LimitPoint]
    let provider: LimitProvider
    let current: LimitsTopicSnapshot?
}

@MainActor final class UsageUICommands {
    private let controller: UsageWorkerController
    private let directory: URL
    private let defaults: UserDefaults
    private var documents: [UUID: (data: Data, expires: Date)] = [:]
    private var stopped = false
    private let exports: UsageExportDelivery
    private let navigate: @MainActor (UsageNavigationRequest) async throws -> Void

    init(
        controller: UsageWorkerController, directory: URL = Repo.dataDir,
        defaults: UserDefaults = SharedDefaults.store, exports: UsageExportDelivery? = nil,
        navigate: @escaping @MainActor (UsageNavigationRequest) async throws -> Void = { _ in
            throw ExtensionPeerError.unavailable
        }
    ) {
        self.navigate = navigate
        self.controller = controller; self.directory = directory; self.defaults = defaults
        self.exports = exports ?? UsageExportDelivery()
    }

    func shutdown() { stopped = true; documents = [:]; exports.stop() }

    func shutdownAndWait() async {
        shutdown()
        await exports.stopAndWait()
    }

    func execute(_ command: String, payload: Data) async throws -> Data {
        try Task.checkCancellation()
        guard !stopped, payload.count <= 131_072,
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { throw ExtensionPeerError.invalidRequest }
        if command.hasPrefix("usage.ui.export.") {
            return try await exports.execute(command, payload: payload)
        }
        documents = documents.filter { $0.value.expires > Date() }
        let encoder = JSONEncoder()
        switch command {
        case "usage.ui.document":
            try empty(object)
            let directory = directory
            let read = Task.detached(priority: .utility) {
                try UsageDataFiles.readRegularFile(
                    at: directory.appendingPathComponent("usage.json"), maximumBytes: 67_108_864)
            }
            let data = try await withTaskCancellationHandler {
                try await read.value
            } onCancel: {
                read.cancel()
            }
            try Task.checkCancellation()
            guard !stopped, let data, UsageHistory.isValidDocument(data) else {
                throw ExtensionPeerError.unavailable
            }
            return try receipt(data)
        case "usage.ui.chunk":
            guard Set(object.keys) == ["id", "offset"],
                let text = object["id"] as? String, let id = UUID(uuidString: text),
                let offset = object["offset"] as? Int, let data = documents[id]?.data,
                (0..<data.count).contains(offset)
            else { throw ExtensionPeerError.invalidRequest }
            let end = min(data.count, offset + 262_144)
            let reply = try encoder.encode(
                UsageMachinesPeer.Chunk(
                    offset: offset, data: data.subdata(in: offset..<end),
                    finished: end == data.count))
            if end == data.count { documents[id] = nil }
            return reply
        case "usage.ui.release":
            guard Set(object.keys) == ["id"], let text = object["id"] as? String,
                let id = UUID(uuidString: text)
            else { throw ExtensionPeerError.invalidRequest }
            documents[id] = nil
            return Data("{}".utf8)
        case "usage.ui.open":
            let request = try JSONDecoder().decode(UsageNavigationRequest.self, from: payload)
            try request.validate()
            guard Set(object.keys) == ["presentationID", "location"] else {
                throw ExtensionPeerError.invalidRequest
            }
            try await navigate(request)
            try Task.checkCancellation()
            guard !stopped else { throw ExtensionPeerError.unavailable }
            return Data("{}".utf8)
        case "usage.ui.compact.limits":
            let request = try SurfaceSnapshotRequest.decode(payload, providerID: "usage")
            guard request.tile.widget == .limits else { throw ExtensionPeerError.invalidRequest }
            let snapshot: LimitsTopicSnapshot
            if let current = controller.latestLimits {
                snapshot = current
            } else {
                let latest = await LimitsHistory.loadLatestProviders(
                    url: directory.appendingPathComponent("limits-history.jsonl"))
                snapshot = LimitsTopicSnapshot(
                    refreshedAt: latest.values.map(\.date).max() ?? .distantPast,
                    providers: LimitProvider.allCases.compactMap { provider in
                        latest[provider].map {
                            .init(
                                provider: provider, session: $0.session, week: $0.week,
                                fable: $0.fable, grok: $0.grok)
                        }
                    }, failure: nil)
            }
            try Task.checkCancellation()
            guard !stopped else { throw ExtensionPeerError.unavailable }
            return try encoder.encode(
                UsageCompactLimitsSnapshot.project(snapshot, tile: request.tile))
        case "usage.ui.card":
            let tile = try JSONDecoder().decode(SurfaceTile.self, from: payload)
            guard [.usage, .activity].contains(tile.widget), (1...365).contains(tile.days),
                (1...100).contains(tile.itemLimit),
                (tile.sourceIDs?.count ?? 0) <= 100,
                tile.sourceIDs?.allSatisfy({
                    !$0.isEmpty && $0.utf8.count <= 2_048 && !$0.utf8.contains(0)
                }) ?? true
            else { throw ExtensionPeerError.invalidRequest }
            let store = SurfaceUsageStore(url: directory.appendingPathComponent("usage.json"))
            let snapshot = try await store.snapshot(tile: tile)
            try Task.checkCancellation()
            guard !stopped else { throw ExtensionPeerError.unavailable }
            return try encoder.encode(snapshot)
        case "usage.ui.presentation":
            try empty(object)
            return try encoder.encode(ExtensionSharedState.current?.values(for: "presenter") ?? [:])
        case "usage.ui.preferences":
            try empty(object)
            return try encoder.encode(UsageUIPreferences.read(defaults))
        case "usage.ui.preferences.set":
            let value = try JSONDecoder().decode(UsageUIPreferences.self, from: payload)
            try value.validate(); value.apply(to: defaults); controller.settingsChanged()
            return Data("{}".utf8)
        case "usage.ui.limits.latest":
            try empty(object)
            let providers = await LimitsHistory.loadLatestProviders(
                url: directory.appendingPathComponent("limits-history.jsonl"))
            try Task.checkCancellation()
            guard !stopped else { throw ExtensionPeerError.unavailable }
            return try encoder.encode(
                UsageUILimitsSummary(providers: providers, current: controller.latestLimits))
        case "usage.ui.limits":
            guard Set(object.keys) == ["provider"], let text = object["provider"] as? String,
                let provider = LimitProvider(rawValue: text)
            else {
                throw ExtensionPeerError.invalidRequest
            }
            let snapshot = await LimitsHistory.loadSnapshot(
                preferredProvider: provider,
                url: directory.appendingPathComponent("limits-history.jsonl"))
            try Task.checkCancellation()
            guard !stopped else { throw ExtensionPeerError.unavailable }
            return try receipt(
                encoder.encode(
                    UsageUILimits(
                        providers: snapshot.latest, points: snapshot.points,
                        provider: snapshot.provider, current: controller.latestLimits
                    )))
        case "usage.ui.log":
            try empty(object)
            return try encoder.encode(
                FileTail.read(
                    directory.appendingPathComponent("refresh.log"), maxBytes: 65_536))
        case "usage.ui.alerts":
            try empty(object)
            let clock = LimitAlertClock()
            return try encoder.encode(
                LimitAlertInspector.inspect(
                    clock: clock, defaults: defaults,
                    historyURL: directory.appendingPathComponent("limits-history.jsonl"),
                    ledger: nil
                ).map { $0.summary(clock: clock) })
        case "usage.ui.notifications.test":
            try empty(object)
            guard UsageExecutionEnvironment.fixtureHome == nil else {
                throw ExtensionPeerError.rejected("Notifications require the installed engine.")
            }
            return try encoder.encode(await LimitNotifier.shared.sendTest())
        case "usage.ui.notifications.authorize":
            try empty(object)
            guard UsageExecutionEnvironment.fixtureHome == nil else {
                throw ExtensionPeerError.rejected("Notifications require the installed engine.")
            }
            return try encoder.encode(
                try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge]))
        case "usage.ui.project.open", "usage.ui.project.copy", "usage.ui.chat.copy":
            let key = command == "usage.ui.chat.copy" ? "chatID" : "repositoryID"
            guard Set(object.keys) == [key], let identifier = object[key] as? String,
                !identifier.isEmpty, identifier.utf8.count <= 4_096,
                let data = try UsageDataFiles.readRegularFile(
                    at: directory.appendingPathComponent("usage.json"), maximumBytes: 67_108_864)
            else { throw ExtensionPeerError.invalidRequest }
            let document = try JSONDecoder().decode(DashUsage.self, from: data)
            let projects = document.daily.flatMap { $0.projects ?? [] }
            if command == "usage.ui.chat.copy" {
                let chats = projects.flatMap {
                    ($0.chats ?? []) + ($0.worktrees ?? []).flatMap { $0.chats ?? [] }
                }
                guard chats.contains(where: { $0.id == identifier }) else {
                    throw ExtensionPeerError.invalidRequest
                }
                return try encoder.encode(
                    UsageProjectOperationExecution.copyChatID(identifier).value)
            }
            guard
                let project = projects.first(where: {
                    DashboardComputation.repositoryID($0) == identifier
                })
            else { throw ExtensionPeerError.invalidRequest }
            let target = UsageProjectTarget(
                repositoryID: identifier,
                repositoryName: project.repositoryName ?? project.projectName ?? identifier,
                repositoryURL: project.repositoryURL)
            let result =
                try command == "usage.ui.project.open"
                ? UsageProjectOperationExecution.openRepository(target)
                : UsageProjectOperationExecution.copyRepositoryLink(target)
            return try encoder.encode(result.value)
        case "usage.ui.machines":
            try empty(object)
            let machines =
                SurfaceHostContext.current?.activeIDs.contains("machines") == true
                ? MachineRegistry.machines().filter { $0.id != Machine.localID } : []
            return try encoder.encode(machines)
        default: throw ExtensionPeerError.invalidRequest
        }
    }

    private func receipt(_ data: Data) throws -> Data {
        guard !stopped, (1...67_108_864).contains(data.count), documents.count < 8 else {
            throw ExtensionPeerError.unavailable
        }
        let id = UUID()
        documents[id] = (data, Date().addingTimeInterval(60))
        return try JSONSerialization.data(withJSONObject: [
            "id": id.uuidString, "byteCount": data.count, "sha256": UsageMachinesPeer.hash(data),
        ])
    }

    private func empty(_ object: [String: Any]) throws {
        guard object.isEmpty else { throw ExtensionPeerError.invalidRequest }
    }
}
