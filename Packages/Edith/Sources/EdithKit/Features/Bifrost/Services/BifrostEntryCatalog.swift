import Foundation

public enum BifrostEntryCatalog {
    public static func entries(
        sources: Set<BifrostSource>, quicklinks: [BifrostQuicklink] = [],
        snippets: [BifrostSnippet] = [], shellCommands: [BifrostShellCommand] = [],
        shortcuts: [String] = [], runningApplications: [BifrostRunningApplication] = [],
        openWindows: [BifrostWindowHandle] = []
    ) -> [BifrostEntry] {
        var entries: [BifrostEntry] = []
        if sources.contains(.quicklinks) {
            entries += quicklinks.filter(\.isValid).map(entry(for:))
        }
        if sources.contains(.snippets) {
            entries += snippets.filter(\.isValid).map(entry(for:))
        }
        if sources.contains(.shellCommands) {
            entries += shellCommands.filter(\.isValid).map(entry(for:))
        }
        if sources.contains(.appleShortcuts) {
            entries += shortcuts.map(entry(forShortcut:))
        }
        if sources.contains(.windowActions) {
            entries += BifrostWindowAction.allCases.map(entry(for:))
        }
        if sources.contains(.systemActions) {
            entries += BifrostSystemAction.allCases.map(entry(for:))
        }
        if sources.contains(.runningApplications) {
            entries += runningApplications.flatMap(entries(for:))
        }
        if sources.contains(.openWindows) {
            entries += openWindows.map(entry(for:))
        }
        return entries
    }

    public static func entry(for quicklink: BifrostQuicklink) -> BifrostEntry {
        let keyword = trimmed(quicklink.keyword)
        return BifrostEntry(
            id: "quicklink:" + quicklink.id, kind: .quicklink, title: quicklink.name,
            subtitle: quicklink.target, symbolName: "link",
            terms: ["quicklink", "link", "open"] + (keyword.map { [$0] } ?? []),
            action: .quicklink(id: quicklink.id), copyText: quicklink.target,
            keyword: keyword)
    }

    public static func entry(for snippet: BifrostSnippet) -> BifrostEntry {
        let keyword = trimmed(snippet.keyword)
        return BifrostEntry(
            id: "snippet:" + snippet.id, kind: .snippet, title: snippet.name,
            subtitle: snippet.preview, symbolName: "text.append",
            terms: ["snippet", "text", "paste"] + (keyword.map { [$0] } ?? []),
            action: .snippet(id: snippet.id), copyText: snippet.content, keyword: keyword)
    }

    public static func entry(for command: BifrostShellCommand) -> BifrostEntry {
        let keyword = trimmed(command.keyword)
        return BifrostEntry(
            id: "shell:" + command.id, kind: .shellCommand, title: command.name,
            subtitle: command.script, symbolName: "terminal",
            terms: ["command", "shell", "script", "run"] + (keyword.map { [$0] } ?? []),
            action: .shell(id: command.id), copyText: command.script, keyword: keyword)
    }

    public static func entry(forShortcut name: String) -> BifrostEntry {
        BifrostEntry(
            id: "shortcut:" + name, kind: .shortcut, title: name, subtitle: "Apple Shortcut",
            symbolName: "square.stack.3d.down.right",
            terms: ["shortcut", "shortcuts", "automation", "run"],
            action: .shortcut(name: name), copyText: name)
    }

    public static func entry(for action: BifrostWindowAction) -> BifrostEntry {
        BifrostEntry(
            id: "window:" + action.rawValue, kind: .windowAction, title: action.title,
            subtitle: "Move or resize the front window", symbolName: action.symbolName,
            terms: action.keywords, action: .window(action), copyText: action.title)
    }

    public static func entry(for action: BifrostSystemAction) -> BifrostEntry {
        BifrostEntry(
            id: "system:" + action.rawValue, kind: .systemAction, title: action.title,
            subtitle: action.subtitle, symbolName: action.symbolName, terms: action.keywords,
            action: .system(action), copyText: action.title)
    }

    public static func entries(
        for application: BifrostRunningApplication
    ) -> [BifrostEntry] {
        [
            BifrostEntry(
                id: "activate:" + application.bundleID, kind: .runningApp,
                title: application.name, subtitle: "Switch to this app", symbolName: "bolt",
                iconPath: application.path, terms: ["running", "switch", "focus"],
                action: .activate(bundleID: application.bundleID), copyText: application.name),
            BifrostEntry(
                id: "quit:" + application.bundleID, kind: .runningApp,
                title: "Quit \(application.name)", subtitle: "Ask this app to quit",
                symbolName: "xmark.circle", iconPath: application.path,
                terms: ["quit", "close", "exit"],
                action: .quit(bundleID: application.bundleID), copyText: application.name),
        ]
    }

    public static func entry(for window: BifrostWindowHandle) -> BifrostEntry {
        BifrostEntry(
            id: "focus:\(window.windowNumber)", kind: .openWindow, title: window.title,
            subtitle: window.ownerName, symbolName: "macwindow.on.rectangle",
            terms: ["window", "switch", window.ownerName],
            action: .focusWindow(processID: window.processID, title: window.title),
            copyText: window.title)
    }

    public static func keywords(in entries: [BifrostEntry]) -> [String: BifrostEntry] {
        var found: [String: BifrostEntry] = [:]
        for entry in entries {
            guard let keyword = entry.keyword?.lowercased(), found[keyword] == nil else {
                continue
            }
            found[keyword] = entry
        }
        return found
    }

    private static func trimmed(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
