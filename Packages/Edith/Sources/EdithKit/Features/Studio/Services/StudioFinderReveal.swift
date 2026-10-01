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
        let revealed = await runScript(script(for: urls), timeout: 4)
        guard revealed else {
            for folder in folders(of: urls) { NSWorkspace.shared.open(folder) }
            return
        }
    }

    public static func runScript(_ source: String, timeout: TimeInterval) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
                return false
            }
            return process.terminationStatus == 0
        }.value
    }
}
