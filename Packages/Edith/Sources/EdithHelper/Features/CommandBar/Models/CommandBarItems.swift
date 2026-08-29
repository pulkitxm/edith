import AppKit
import EdithKit
import Foundation

enum CommandBarActionID: String, CaseIterable, Sendable {
    case openHome
    case openExtensions
    case openGeneralSettings
    case openShortcuts
    case openPermissions
    case openAttention
    case openUsage
    case openHerdr
    case openQuinjet
    case openMusic
    case openCalendar
    case openSystem
    case openMachines
    case openCompanion
    case openCommandBarSettings
    case clipboard
    case colorPicker
    case micMute
    case focusDim
}

enum CommandBarApplicationAction: String, Sendable {
    case open
    case reveal
    case quit
    case relaunch
}

struct CommandBarApplication: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let url: URL
    let bundleIdentifier: String?
    let runningPID: pid_t?

    var subtitle: String {
        if runningPID != nil { return "Running application" }
        return bundleIdentifier ?? url.deletingPathExtension().lastPathComponent
    }
}

struct CommandBarSelection: Equatable, Sendable {
    let processIdentifier: pid_t
    let text: String
}

enum CommandBarItemKind: Sendable {
    case action(CommandBarActionID)
    case application(CommandBarApplication, CommandBarApplicationAction)
    case answer(CommandBarAnswer)
    case file(URL)
    case systemSettings(URL)
    case clipboard(ClipboardEntry)
    case emoji(String)
    case textUtility(CommandBarTextUtility, CommandBarSelection)
}

struct CommandBarItem: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let symbolName: String
    let keywords: [String]
    let sourceBias: Int
    let kind: CommandBarItemKind
    var pinned = false
    var shortcutLabel: String?

    var candidate: CommandBarCandidate {
        CommandBarCandidate(
            id: id, title: title, subtitle: subtitle, keywords: keywords,
            bias: sourceBias + (pinned ? 60 : 0))
    }
}

enum CommandBarApplicationCatalog {
    static let defaultRoots = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Applications", isDirectory: true),
    ]

    static func load(
        roots: [URL] = defaultRoots, fileManager: FileManager = .default
    ) -> [CommandBarApplication] {
        let pairs = NSWorkspace.shared.runningApplications.compactMap { app in
            app.bundleIdentifier.map { ($0, app.processIdentifier) }
        }
        let running = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        var applications: [String: CommandBarApplication] = [:]
        for root in roots {
            guard
                let enumerator = fileManager.enumerator(
                    at: root, includingPropertiesForKeys: [.isApplicationKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
                guard let application = application(at: url, running: running) else { continue }
                let key = application.bundleIdentifier ?? url.standardizedFileURL.path
                if applications[key] == nil { applications[key] = application }
            }
        }
        return applications.values.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    static func application(
        at url: URL, running: [String: pid_t] = [:]
    ) -> CommandBarApplication? {
        guard let bundle = Bundle(url: url) else { return nil }
        let title =
            bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let bundleIdentifier = bundle.bundleIdentifier
        return CommandBarApplication(
            id: "app.\(bundleIdentifier ?? url.standardizedFileURL.path)", title: clean,
            url: url.standardizedFileURL, bundleIdentifier: bundleIdentifier,
            runningPID: bundleIdentifier.flatMap { running[$0] })
    }
}
