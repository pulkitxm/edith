import AppKit
import Darwin
import EdithCore
import Foundation

public struct AppInfoSnapshot: Equatable, Sendable {
    public let name: String
    public let version: String
    public let build: String
    public let bundleID: String?
    public let bundlePath: String
    public let repositoryURL: URL
    public let creatorURL: URL

    public init(
        name: String, version: String, build: String, bundleID: String?, bundlePath: String,
        repositoryURL: URL, creatorURL: URL
    ) {
        self.name = name
        self.version = version
        self.build = build
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.repositoryURL = repositoryURL
        self.creatorURL = creatorURL
    }
}

public struct AppDiagnosticsSnapshot: Equatable, Sendable {
    public let info: AppInfoSnapshot
    public let processID: Int32
    public let uptimeSeconds: Int
    public let idleWakeups: Int

    public init(
        info: AppInfoSnapshot, processID: Int32, uptimeSeconds: Int, idleWakeups: Int
    ) {
        self.info = info
        self.processID = processID
        self.uptimeSeconds = uptimeSeconds
        self.idleWakeups = idleWakeups
    }

    public var uptimeText: String {
        let hours = uptimeSeconds / 3600
        let minutes = (uptimeSeconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

public enum AppPathID: String, CaseIterable, Equatable, Sendable {
    case appData = "app-data"
    case icloud
    case data
    case refreshLog = "refresh-log"
    case music
}

public struct AppPathSnapshot: Equatable, Sendable {
    public let id: AppPathID
    public let label: String
    public let url: URL
    public let exists: Bool

    public init(id: AppPathID, label: String, url: URL, exists: Bool) {
        self.id = id
        self.label = label
        self.url = url
        self.exists = exists
    }
}

public struct AppExternalLink: Equatable, Sendable {
    public let id: String
    public let label: String
    public let url: URL

    public init(id: String, label: String, url: URL) {
        self.id = id
        self.label = label
        self.url = url
    }
}

public struct AppOpenResult: Equatable, Sendable {
    public enum Mode: String, Equatable, Sendable {
        case open
        case reveal
    }

    public let id: String
    public let url: URL
    public let mode: Mode
    public let opened: Bool

    public init(id: String, url: URL, mode: Mode, opened: Bool) {
        self.id = id
        self.url = url
        self.mode = mode
        self.opened = opened
    }
}

public enum AppInspectionError: Error, Equatable, Sendable {
    case unknownLink(String)
    case couldNotOpen(String)
}

public enum AppInspectionOperation: String, CaseIterable, Equatable, Sendable {
    case info
    case diagnostics
    case paths
    case links
    case openPath
    case openLink

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .info:
            descriptor("info", "Read Edith's application identity.", .read)
        case .diagnostics:
            descriptor("diagnostics", "Read live Edith process diagnostics.", .read)
        case .paths:
            descriptor("paths", "List the folders and files Edith exposes.", .read)
        case .links:
            descriptor("links", "List Edith's external links.", .read)
        case .openPath:
            descriptor("open-path", "Open or reveal one Edith path.", .interactive)
        case .openLink:
            descriptor("open-link", "Open one Edith external link.", .interactive)
        }
    }

    private func descriptor(
        _ command: String, _ summary: String, _ effect: UserOperationEffect
    ) -> UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "app.\(rawValue)"), summary: summary,
            cli: ["app", command], effect: effect)
    }
}

public enum AppProcessUptime {
    public static let launchedAt = Date()
}

public struct AppInspectionCenter {
    public typealias Exists = (URL) -> Bool
    public typealias CreateDirectory = (URL) throws -> Void
    public typealias Open = (URL) -> Bool
    public typealias Reveal = ([URL]) -> Void
    public typealias IdleWakeups = () -> Int

    public static let repositoryURL = URL(string: "https://github.com/pulkitxm/edith")!
    public static let creatorURL = URL(string: MainApp.creatorSiteURLString)!
    public static let repositorySourceURL = URL(
        string: "https://github.com/pulkitxm/edith/blob/main/")!

    private let exists: Exists
    private let createDirectory: CreateDirectory
    private let open: Open
    private let reveal: Reveal
    private let idleWakeups: IdleWakeups

    public init(
        exists: @escaping Exists = { FileManager.default.fileExists(atPath: $0.path) },
        createDirectory: @escaping CreateDirectory = {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        },
        open: @escaping Open = { NSWorkspace.shared.open($0) },
        reveal: @escaping Reveal = { NSWorkspace.shared.activateFileViewerSelecting($0) },
        idleWakeups: @escaping IdleWakeups = Self.liveIdleWakeups
    ) {
        self.exists = exists
        self.createDirectory = createDirectory
        self.open = open
        self.reveal = reveal
        self.idleWakeups = idleWakeups
    }

    public func info(bundle: Bundle = .main) -> AppInfoSnapshot {
        let dictionary = bundle.infoDictionary
        return AppInfoSnapshot(
            name: dictionary?["CFBundleName"] as? String ?? "Edith",
            version: dictionary?["CFBundleShortVersionString"] as? String ?? "-",
            build: dictionary?["CFBundleVersion"] as? String ?? "-",
            bundleID: bundle.bundleIdentifier, bundlePath: bundle.bundleURL.path,
            repositoryURL: Self.repositoryURL, creatorURL: Self.creatorURL)
    }

    public func diagnostics(
        bundle: Bundle = .main, launchedAt: Date = AppProcessUptime.launchedAt,
        now: Date = Date(), processID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> AppDiagnosticsSnapshot {
        AppDiagnosticsSnapshot(
            info: info(bundle: bundle), processID: processID,
            uptimeSeconds: max(0, Int(now.timeIntervalSince(launchedAt))),
            idleWakeups: idleWakeups())
    }

    public func paths() -> [AppPathSnapshot] {
        let entries: [(AppPathID, String, URL)] = [
            (.appData, "App data", AppData.supportDir),
            (.icloud, "iCloud", AppData.cloudDir),
            (.data, "Usage data", Repo.dataDir),
            (.refreshLog, "Refresh log", Repo.dataDir.appendingPathComponent("refresh.log")),
            (.music, "Music", Repo.musicDir),
        ]
        return entries.map { id, label, url in
            AppPathSnapshot(id: id, label: label, url: url, exists: exists(url))
        }
    }

    public func links(contributors: [Contributor] = Contributors.cached()) -> [AppExternalLink] {
        [
            AppExternalLink(id: "repository", label: "pulkitxm/edith", url: Self.repositoryURL),
            AppExternalLink(id: "creator", label: "Pulkit", url: Self.creatorURL),
        ]
            + extensionDocumentationLinks()
            + contributors.map {
                AppExternalLink(
                    id: "contributor:\($0.login)", label: $0.login, url: $0.profileURL)
            }
    }

    public func extensionDocumentationLinks(
        entries: [ExtensionRegistryEntry] = ExtensionRegistry.entries
    ) -> [AppExternalLink] {
        entries.flatMap { entry in
            entry.lifecycle?.documentation.compactMap { document in
                guard
                    let url = URL(string: document.path, relativeTo: Self.repositorySourceURL)?
                        .absoluteURL
                else { return nil }
                return AppExternalLink(
                    id: Self.extensionDocumentationID(
                        extensionID: entry.id, documentID: document.id),
                    label: "\(entry.title): \(document.title)", url: url)
            } ?? []
        }
    }

    public static func extensionDocumentationID(
        extensionID: String, documentID: String
    ) -> String {
        "extension-doc:\(extensionID):\(documentID)"
    }

    public func openPath(_ id: AppPathID) throws -> AppOpenResult {
        let entry = paths().first { $0.id == id }!
        if [.icloud, .music].contains(id), !entry.exists {
            try createDirectory(entry.url)
        }
        if id == .refreshLog, entry.exists {
            reveal([entry.url])
            return AppOpenResult(id: id.rawValue, url: entry.url, mode: .reveal, opened: true)
        }
        let target = id == .refreshLog ? Repo.dataDir : entry.url
        let opened = open(target)
        guard opened else { throw AppInspectionError.couldNotOpen(target.path) }
        return AppOpenResult(id: id.rawValue, url: target, mode: .open, opened: true)
    }

    public func openLink(
        _ id: String, contributors: [Contributor] = Contributors.cached()
    ) throws -> AppOpenResult {
        guard
            let link = links(contributors: contributors).first(where: {
                $0.id.caseInsensitiveCompare(id) == .orderedSame
            })
        else { throw AppInspectionError.unknownLink(id) }
        let opened = open(link.url)
        guard opened else { throw AppInspectionError.couldNotOpen(link.url.absoluteString) }
        return AppOpenResult(id: link.id, url: link.url, mode: .open, opened: true)
    }

    public static func liveIdleWakeups() -> Int {
        var info = task_power_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_power_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.task_platform_idle_wakeups) : 0
    }
}

public enum AppDiagnosticsPayload {
    public static func encode(_ snapshot: AppDiagnosticsSnapshot) -> [String: Any] {
        [
            "name": snapshot.info.name,
            "version": snapshot.info.version,
            "build": snapshot.info.build,
            "bundleID": snapshot.info.bundleID ?? "",
            "bundlePath": snapshot.info.bundlePath,
            "pid": Int(snapshot.processID),
            "uptimeSeconds": snapshot.uptimeSeconds,
            "idleWakeups": snapshot.idleWakeups,
        ]
    }

    public static func decode(_ payload: [AnyHashable: Any]) -> AppDiagnosticsSnapshot? {
        guard let name = payload["name"] as? String,
            let version = payload["version"] as? String,
            let build = payload["build"] as? String,
            let bundlePath = payload["bundlePath"] as? String,
            let pid = payload["pid"] as? Int,
            let uptimeSeconds = payload["uptimeSeconds"] as? Int,
            let idleWakeups = payload["idleWakeups"] as? Int
        else { return nil }
        let bundleID = (payload["bundleID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let info = AppInfoSnapshot(
            name: name, version: version, build: build, bundleID: bundleID,
            bundlePath: bundlePath, repositoryURL: AppInspectionCenter.repositoryURL,
            creatorURL: AppInspectionCenter.creatorURL)
        return AppDiagnosticsSnapshot(
            info: info, processID: Int32(pid), uptimeSeconds: uptimeSeconds,
            idleWakeups: idleWakeups)
    }
}
