import AppKit
import CoreServices
import EdithKit
import Foundation

struct CommandBarProviderContext: Sendable {
    let query: String
    let applications: [CommandBarApplication]
    let clipboardEntries: [ClipboardEntry]
    let selection: CommandBarSelection?
    let fileScopes: [String]
}

protocol CommandBarProvider: Sendable {
    func results(for context: CommandBarProviderContext) async -> [CommandBarItem]
}

struct CommandBarApplicationProvider: CommandBarProvider {
    func results(for context: CommandBarProviderContext) async -> [CommandBarItem] {
        guard !Task.isCancelled else { return [] }
        return context.applications.flatMap { application in
            var items = [item(application, action: .open)]
            items.append(item(application, action: .reveal))
            if application.runningPID != nil {
                items.append(item(application, action: .quit))
                items.append(item(application, action: .relaunch))
            }
            return items
        }
    }

    private func item(
        _ application: CommandBarApplication, action: CommandBarApplicationAction
    ) -> CommandBarItem {
        let title: String
        let subtitle: String
        let symbol: String
        let id: String
        switch action {
        case .open:
            title = application.title
            subtitle = application.subtitle
            symbol = "app.fill"
            id = application.id
        case .reveal:
            title = "Reveal \(application.title)"
            subtitle = "Show application in Finder"
            symbol = "folder"
            id = "app-action.reveal.\(application.id)"
        case .quit:
            title = "Quit \(application.title)"
            subtitle = "Ask the running application to quit"
            symbol = "xmark.circle"
            id = "app-action.quit.\(application.id)"
        case .relaunch:
            title = "Relaunch \(application.title)"
            subtitle = "Quit and reopen the application"
            symbol = "arrow.clockwise"
            id = "app-action.relaunch.\(application.id)"
        }
        return CommandBarItem(
            id: id, title: title, subtitle: subtitle, symbolName: symbol,
            keywords: [application.bundleIdentifier ?? "", "application", "app", action.rawValue],
            sourceBias: 0, kind: .application(application, action))
    }
}

struct CommandBarClipboardProvider: CommandBarProvider {
    func results(for context: CommandBarProviderContext) async -> [CommandBarItem] {
        guard !Task.isCancelled, !context.clipboardEntries.isEmpty else { return [] }
        let query = CommandBarSearch.normalized(context.query)
        let entries = ClipboardActions.arrange(context.clipboardEntries, query: query)
        return entries.prefix(query.isEmpty ? 3 : 8).map { entry in
            CommandBarItem(
                id: "clipboard.\(entry.id)",
                title: entry.preview?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(120).description ?? entry.kind.rawValue.capitalized,
                subtitle: entry.sourceApp.map { "Clipboard from \($0)" } ?? "Clipboard history",
                symbolName: entry.kind == .text ? "doc.on.clipboard" : "photo.on.rectangle",
                keywords: [entry.sourceApp ?? "", "clipboard", "paste", entry.kind.rawValue],
                sourceBias: -10, kind: .clipboard(entry))
        }
    }
}

struct CommandBarEmojiProvider: CommandBarProvider {
    func results(for context: CommandBarProviderContext) async -> [CommandBarItem] {
        guard !Task.isCancelled else { return [] }
        let query = CommandBarSearch.normalized(context.query)
        guard
            query.hasPrefix("emoji")
                || CommandBarEmoji.common.contains(where: {
                    $0.keywords.contains(where: { $0.hasPrefix(query) || $0.contains(query) })
                })
        else { return [] }
        return CommandBarEmoji.common.map { emoji in
            let scalarID = emoji.character.unicodeScalars.map {
                String($0.value, radix: 16)
            }.joined(separator: "-")
            return CommandBarItem(
                id: "emoji.\(scalarID)", title: emoji.character,
                subtitle: emoji.keywords.first?.capitalized ?? "Emoji",
                symbolName: "face.smiling", keywords: ["emoji"] + emoji.keywords,
                sourceBias: -20, kind: .emoji(emoji.character))
        }
    }
}

struct CommandBarTextUtilityProvider: CommandBarProvider {
    func results(for context: CommandBarProviderContext) async -> [CommandBarItem] {
        guard !Task.isCancelled, let selection = context.selection else { return [] }
        return CommandBarTextUtility.allCases.map { utility in
            let transformed = utility.transform(selection.text)
            let detail =
                utility == .countWords
                ? "\(transformed) words in selected text" : "Replace selected text"
            return CommandBarItem(
                id: "text-utility.\(utility.rawValue)", title: utility.title, subtitle: detail,
                symbolName: utility.symbolName,
                keywords: ["selected text", "selection", "transform", utility.rawValue],
                sourceBias: 20, kind: .textUtility(utility, selection))
        }
    }
}

struct CommandBarSystemSettingsProvider: CommandBarProvider {
    func results(for context: CommandBarProviderContext) async -> [CommandBarItem] {
        guard !Task.isCancelled else { return [] }
        return Self.panes().map { pane in
            CommandBarItem(
                id: "system-settings.\(pane.bundleIdentifier)", title: pane.title,
                subtitle: "System Settings", symbolName: "gearshape.2",
                keywords: pane.keywords, sourceBias: -5, kind: .systemSettings(pane.url))
        }
    }

    private struct Pane: Sendable {
        let bundleIdentifier: String
        let title: String
        let keywords: [String]
        let url: URL
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: [Pane]?

    private static func panes() -> [Pane] {
        lock.withLock {
            if let cached { return cached }
            let value = scan()
            cached = value
            return value
        }
    }

    private static func scan() -> [Pane] {
        let root = URL(
            fileURLWithPath: "/System/Library/ExtensionKit/Extensions", isDirectory: true)
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return fallbackPanes }
        let panes = contents.compactMap { url -> Pane? in
            guard url.pathExtension == "appex", let bundle = Bundle(url: url),
                let info = bundle.infoDictionary,
                let attributes = info["EXAppExtensionAttributes"] as? [String: Any],
                let settings = attributes["SettingsExtensionAttributes"] as? [String: Any],
                settings["allowsXAppleSystemPreferencesURLScheme"] as? Bool == true,
                let bundleIdentifier = bundle.bundleIdentifier,
                let destination = URL(string: "x-apple.systempreferences:\(bundleIdentifier)")
            else { return nil }
            let title =
                bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
                ?? info["CFBundleDisplayName"] as? String
                ?? info["CFBundleName"] as? String
                ?? url.deletingPathExtension().lastPathComponent
            return Pane(
                bundleIdentifier: bundleIdentifier, title: title,
                keywords: ["system", "settings", "preferences", title], url: destination)
        }
        return panes.isEmpty
            ? fallbackPanes
            : panes.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static let fallbackPanes: [Pane] = [
        pane("com.apple.Displays-Settings.extension", "Displays", ["resolution", "monitor"]),
        pane("com.apple.Sound-Settings.extension", "Sound", ["audio", "volume", "input"]),
        pane("com.apple.Network-Settings.extension", "Network", ["wifi", "ethernet", "vpn"]),
        pane("com.apple.BluetoothSettings", "Bluetooth", ["devices", "wireless"]),
        pane("com.apple.Accessibility-Settings.extension", "Accessibility", ["vision", "motor"]),
        pane(
            "com.apple.settings.PrivacySecurity.extension", "Privacy & Security",
            ["permissions"]),
        pane("com.apple.Keyboard-Settings.extension", "Keyboard", ["input", "shortcuts"]),
        pane("com.apple.Trackpad-Settings.extension", "Trackpad", ["gestures", "mouse"]),
    ]

    private static func pane(_ id: String, _ title: String, _ keywords: [String]) -> Pane {
        Pane(
            bundleIdentifier: id, title: title, keywords: ["system", "settings"] + keywords,
            url: URL(string: "x-apple.systempreferences:\(id)")!)
    }
}

struct CommandBarFileProvider: CommandBarProvider {
    func results(for context: CommandBarProviderContext) async -> [CommandBarItem] {
        guard !context.fileScopes.isEmpty,
            let expression = CommandBarFileSearchSupport.expression(for: context.query)
        else { return [] }
        let search = CommandBarMetadataSearch()
        let paths = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                search.run(expression: expression, scopes: context.fileScopes)
            }.value
        } onCancel: {
            search.cancel()
        }
        guard !Task.isCancelled else { return [] }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return paths.map { path in
            let url = URL(fileURLWithPath: path)
            return CommandBarItem(
                id: "file.\(path)", title: url.lastPathComponent,
                subtitle: CommandBarFileSearchSupport.abbreviating(
                    url.deletingLastPathComponent().path, homeDirectory: home),
                symbolName: "doc.text.magnifyingglass",
                keywords: ["file", "folder", url.pathExtension], sourceBias: -40,
                kind: .file(url))
        }
    }
}

private final class CommandBarMetadataSearch: @unchecked Sendable {
    private let lock = NSLock()
    private var query: MDQuery?
    private var cancelled = false

    func cancel() {
        lock.withLock {
            cancelled = true
            if let query { MDQueryStop(query) }
            query = nil
        }
    }

    func run(expression: String, scopes: [String]) -> [String] {
        let liveScopes = scopes.filter(Self.isSearchableDirectory)
        guard !liveScopes.isEmpty,
            let created = MDQueryCreate(kCFAllocatorDefault, expression as CFString, nil, nil)
        else { return [] }
        let canStart = lock.withLock {
            guard !cancelled else { return false }
            query = created
            return true
        }
        guard canStart else { return [] }
        defer { lock.withLock { query = nil } }
        MDQuerySetMaxCount(created, CommandBarFileSearchSupport.candidateLimit)
        MDQuerySetSearchScope(created, liveScopes as CFArray, 0)
        guard MDQueryExecute(created, CFOptionFlags(kMDQuerySynchronous.rawValue)) else {
            return []
        }
        var result: [String] = []
        for index in 0..<MDQueryGetResultCount(created) {
            guard let raw = MDQueryGetResultAtIndex(created, index) else { continue }
            let item = unsafeBitCast(raw, to: MDItem.self)
            if let path = MDItemCopyAttribute(item, kMDItemPath) as? String { result.append(path) }
        }
        let sorted = result.sorted {
            let left = ($0 as NSString).lastPathComponent
            let right = ($1 as NSString).lastPathComponent
            let order = left.localizedCaseInsensitiveCompare(right)
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
        return CommandBarFileSearchSupport.offerable(paths: sorted, isPackage: Self.isPackage)
    }

    private static func isSearchableDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue && !isPackage(path)
    }

    private static func isPackage(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }
}
