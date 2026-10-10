import AppKit
import EdithExtensionSupport
import EdithHostCore
import Foundation
import UserNotifications

@MainActor final class HostAppCLIAdapter {
    typealias Navigation = @MainActor (String, String?) throws -> [String: Any]
    private let identity: HostIdentity
    private let marketplace: HostMarketplace
    private let updater: HostUpdater
    private let showMainWindow: @MainActor () -> Void
    private let navigation: Navigation
    private let relaunch: @MainActor () async throws -> HostCLIJSON
    private let core: @MainActor () -> HostCoreServices?
    private let startedAt = Date()

    init(
        identity: HostIdentity, marketplace: HostMarketplace, updater: HostUpdater,
        showMainWindow: @escaping @MainActor () -> Void,
        navigation: @escaping Navigation,
        core: @escaping @MainActor () -> HostCoreServices? = { nil },
        relaunch: @escaping @MainActor () async throws -> HostCLIJSON
    ) {
        self.identity = identity; self.marketplace = marketplace; self.updater = updater
        self.showMainWindow = showMainWindow; self.navigation = navigation; self.relaunch = relaunch
        self.core = core
    }

    func execute(_ arguments: [String]) async throws -> ExtensionCLIReply {
        try await HostAppCommandCLI(
            available: { [self] in
                var actions = Set(HostAppCommandCLI.actions)
                if !updater.available { actions.remove("check-updates") }
                if !marketplace.sessions.activeIDs.contains("system") {
                    actions.remove("clean-keys")
                }
                return actions
            }, perform: { [self] action, payload in try await perform(action, payload: payload) }
        ).execute(arguments)
    }

    private func perform(_ action: String, payload: [String: HostCLIJSON]) async throws
        -> HostCLIJSON
    {
        switch action {
        case "info": return info()
        case "diagnostics":
            let service = core()
            await service?.refresh()
            try Task.checkCancellation()
            return try HostAppDiagnosticsCLI.process(
                info: info(), startedAt: startedAt,
                agent: HostAppDiagnosticsCLI.core(
                    snapshot: service?.snapshot, online: service?.online == true,
                    state: service?.activityLabel.lowercased() ?? "unavailable",
                    build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                        ?? "development"),
                extensionIDs: Array(marketplace.sessions.activeIDs))
        case "paths":
            return .array(
                HostAppPathsCLI.entries(identity: identity).map { id, label, url in
                    .object([
                        "id": .string(id), "label": .string(label),
                        "path": .string(url.path),
                        "exists": .bool(FileManager.default.fileExists(atPath: url.path)),
                    ])
                })
        case "links":
            return .array(
                links().map { id, label, url in
                    .object([
                        "id": .string(id), "label": .string(label),
                        "url": .string(url.absoluteString),
                    ])
                }.sorted { ($0.object?["id"]?.string ?? "") < ($1.object?["id"]?.string ?? "") })
        case "open-path":
            guard let id = payload["id"]?.string else {
                throw HostCLIError.usage("Unknown app path.")
            }
            let target = try HostAppPathsCLI.prepareOpen(id, identity: identity)
            if target.reveal {
                NSWorkspace.shared.activateFileViewerSelecting([target.url])
            } else {
                guard NSWorkspace.shared.open(target.url) else {
                    throw HostCLIError.rejected("Could not open the app path.")
                }
            }
            return .object([
                "id": .string(id), "url": .string(target.url.absoluteString),
                "mode": .string(target.reveal ? "reveal" : "open"), "opened": .bool(true),
            ])
        case "open-link":
            guard let id = payload["id"]?.string, let link = links().first(where: { $0.id == id })
            else {
                throw HostCLIError.usage("Unknown app link.")
            }
            guard NSWorkspace.shared.open(link.url) else {
                throw HostCLIError.rejected("Could not open the app link.")
            }
            return .object([
                "id": .string(id), "url": .string(link.url.absoluteString), "mode": .string("open"),
                "opened": .bool(true),
            ])
        case "open":
            showMainWindow(); return .object(["action": .string(action), "requested": .bool(true)])
        case "quit":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
            return .object([
                "action": .string(action), "requested": .bool(true), "changed": .bool(true),
            ])
        case "relaunch": return try await relaunch()
        case "check-updates":
            guard updater.available else {
                throw HostCLIError.rejected("The updater is unavailable in this installation.")
            }
            let baseline = updater.checkHistory.first?.id
            updater.checkForUpdatesInBackground()
            if payload["noWait"] == .bool(true) {
                return .object(["requested": .bool(true), "finished": .bool(false)])
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                if let record = updater.checkHistory.first, record.id != baseline {
                    return .object([
                        "requested": .bool(true), "finished": .bool(true),
                        "outcome": .string(record.outcome.rawValue),
                        "version": record.version.map(HostCLIJSON.string) ?? .null,
                        "detail": record.detail.map(HostCLIJSON.string) ?? .null,
                    ])
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw HostCLIError.timedOut
        case "updates":
            let limit = Int(payload["limit"]?.integer ?? 20)
            return .array(
                updater.checkHistory.prefix(limit).map { record in
                    .object([
                        "date": .string(ISO8601DateFormatter().string(from: record.date)),
                        "kind": .string(record.kind.rawValue),
                        "outcome": .string(record.outcome.rawValue),
                        "version": record.version.map(HostCLIJSON.string) ?? .null,
                        "detail": record.detail.map(HostCLIJSON.string) ?? .null,
                    ])
                })
        case "clear-updates":
            let changed = !updater.checkHistory.isEmpty
            updater.clearCheckHistory()
            return .object(["cleared": .bool(true), "changed": .bool(changed)])
        case "route", "navigate", "back", "forward":
            let result = try navigation(action, payload["route"]?.string)
            guard result["ok"] as? Bool == true else {
                throw HostCLIError.rejected(
                    result["error"] as? String ?? "The original window rejected navigation.")
            }
            return try json(result.filter { $0.key != "ok" })
        case "reveal":
            if payload["list"] == .bool(true) {
                return .object([
                    "sections": .array(
                        HostNavigationCatalog.pages.map {
                            .object(["id": .string($0.id), "title": .string($0.title)])
                        })
                ])
            }
            if let section = payload["section"]?.string {
                guard HostNavigationCatalog.pages.contains(where: { $0.id == section })
                else { throw HostCLIError.usage("Unknown sidebar section.") }
                let route = section + (payload["tab"]?.string.map { "/" + $0 } ?? "")
                let result = try navigation("navigate", route)
                guard result["ok"] as? Bool == true else {
                    throw HostCLIError.rejected(
                        result["error"] as? String ?? "The original window rejected this section.")
                }
            }
            showMainWindow()
            return .object([
                "action": .string(action), "requested": .bool(true),
                "section": payload["section"] ?? .null, "tab": payload["tab"] ?? .null,
            ])
        case "snapshot": return try snapshots(directory: payload["dir"]?.string)
        case "test-notification":
            let content = UNMutableNotificationContent()
            content.title = "Edith"; content.body = "Notifications are working.";
            content.sound = .default
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                    identifier: "edith-test-" + UUID().uuidString, content: content, trigger: nil))
            return .object(["action": .string(action), "requested": .bool(true)])
        case "clean-keys":
            let request = try HostCLIRequest(
                action: .invoke, id: "system", operation: "system.cli",
                payload: JSONEncoder().encode(
                    HostCLIInvocationContext(arguments: ["clean-keys", "--json"])))
            let data = try await HostCLIGateway(marketplace: marketplace).execute(request)
            let reply = try JSONDecoder().decode(ExtensionCLIReply.self, from: data)
            try reply.validate()
            guard reply.exitCode == 0 else { throw HostCLIError.rejected(reply.stderr) }
            return try JSONDecoder().decode(HostCLIJSON.self, from: Data(reply.stdout.utf8))
        default: throw HostCLIError.usage("Unknown app action.")
        }
    }

    private func info() -> HostCLIJSON {
        .object([
            "name": .string(
                Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Edith"),
            "version": .string(
                Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                    ?? "development"),
            "build": .string(
                Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                    ?? "development"), "bundleID": .string(identity.identifier),
            "bundlePath": .string(Bundle.main.bundleURL.path),
            "repositoryURL": .string("https://github.com/pulkitxm/edith"),
            "creatorURL": .string("https://pulkit.page"),
        ])
    }
    private func links() -> [(id: String, label: String, url: URL)] {
        HostAppLinksCLI.entries(
            extensions: marketplace.entries,
            contributors: Dictionary(
                HostContributors.cacheSnapshot(identity: identity).people.map {
                    ($0.login, $0.profileURL)
                }, uniquingKeysWith: { first, _ in first }))
    }
    private func json(_ value: Any) throws -> HostCLIJSON {
        try JSONDecoder().decode(
            HostCLIJSON.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func snapshots(directory: String?) throws -> HostCLIJSON {
        let target =
            directory.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("edith-snapshots")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        var files: [String] = []
        for window in NSApp.windows where window.isVisible {
            guard let view = window.contentView,
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { continue }
            let file = target.appendingPathComponent(
                "window-\(window.windowNumber)-\(UUID().uuidString).png")
            try data.write(to: file, options: .atomic)
            files.append(file.path)
        }
        guard !files.isEmpty else {
            throw HostCLIError.rejected("No open app window could be captured.")
        }
        return .object(["files": .strings(files)])
    }
}
