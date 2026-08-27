import AppKit
import EdithKit
import Foundation

enum CommandBarActionID: String, CaseIterable {
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

struct CommandBarApplication: Identifiable, Equatable {
    let id: String
    let title: String
    let url: URL
    let bundleIdentifier: String?

    var subtitle: String {
        bundleIdentifier ?? url.deletingPathExtension().lastPathComponent
    }
}

struct CommandBarItem: Identifiable {
    enum Kind {
        case action(CommandBarActionID)
        case application(CommandBarApplication)
        case answer(CommandBarAnswer)
    }

    let id: String
    let title: String
    let subtitle: String
    let symbolName: String
    let kind: Kind

    var candidate: CommandBarCandidate {
        CommandBarCandidate(
            id: id, title: title, subtitle: subtitle,
            keywords: keywords)
    }

    private var keywords: [String] {
        switch kind {
        case .action(let action):
            switch action {
            case .openHome: ["dashboard", "edith"]
            case .openExtensions: ["features", "plugins", "manage"]
            case .openGeneralSettings: ["preferences", "configure"]
            case .openShortcuts: ["hotkey", "keyboard", "keys"]
            case .openPermissions: ["privacy", "access", "macos"]
            case .openAttention: ["focus", "activity", "time"]
            case .openUsage: ["limits", "tokens", "cost"]
            case .openHerdr: ["agents", "sessions"]
            case .openQuinjet: ["review", "pull request", "terminal"]
            case .openMusic: ["songs", "player", "library"]
            case .openCalendar: ["events", "schedule", "agenda"]
            case .openSystem: ["apps", "sleep", "clean keyboard"]
            case .openMachines: ["ssh", "servers", "remote"]
            case .openCompanion: ["memory", "notes", "voice"]
            case .openCommandBarSettings: ["palette", "configure", "ranking"]
            case .clipboard: ["history", "paste", "copied"]
            case .colorPicker: ["sample", "eyedropper", "hex"]
            case .micMute: ["microphone", "audio", "toggle"]
            case .focusDim: ["dimming", "focus", "toggle"]
            }
        case .application(let application):
            [application.bundleIdentifier ?? "", "application", "app"]
        case .answer:
            ["calculate", "convert", "copy"]
        }
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
        var applications: [String: CommandBarApplication] = [:]
        for root in roots {
            guard
                let enumerator = fileManager.enumerator(
                    at: root, includingPropertiesForKeys: [.isApplicationKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
                guard let application = application(at: url) else { continue }
                let key = application.bundleIdentifier ?? url.standardizedFileURL.path
                if applications[key] == nil { applications[key] = application }
            }
        }
        return applications.values.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    static func application(at url: URL) -> CommandBarApplication? {
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
            url: url.standardizedFileURL, bundleIdentifier: bundleIdentifier)
    }
}
