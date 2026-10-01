import AppKit
import Foundation

public enum StudioFinderReveal {
    public static func script(for urls: [URL]) -> String {
        let targets = urls.map { "POSIX file \"\(escaped($0.path))\" as alias" }
        return """
            set targets to {\(targets.joined(separator: ", "))}
            tell application "Finder"
                reveal targets
                activate
            end tell
            """
    }

    public static func escaped(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    public static func folders(of urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        var folders: [URL] = []
        for url in urls {
            let folder = url.deletingLastPathComponent().standardizedFileURL
            if seen.insert(folder).inserted { folders.append(folder) }
        }
        return folders
    }

    nonisolated(unsafe) public static var revealFiles: @Sendable ([URL]) async -> Void = { urls in
        await revealInFinder(urls)
    }
    nonisolated(unsafe) public static var openFile: @Sendable (URL) -> Void = {
        NSWorkspace.shared.open($0)
    }

    public static func open(_ url: URL) {
        openFile(url)
    }

    @MainActor
    public static func reveal(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        await revealFiles(urls)
    }

    @MainActor
    public static func revealInFinder(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        let source = script(for: urls)
        let revealed = await Task.detached(priority: .userInitiated) {
            guard let script = NSAppleScript(source: source) else { return false }
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            return error == nil
        }.value
        guard !revealed else { return }
        for folder in folders(of: urls) { NSWorkspace.shared.open(folder) }
    }
}
