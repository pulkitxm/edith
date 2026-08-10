import Foundation

public enum CompletionInstallState: String, Equatable, Sendable {
    case missing
    case outdated
    case current
    case foreign
}

public struct CompletionStatus: Equatable, Sendable {
    public var shell: CompletionScripts.Shell
    public var state: CompletionInstallState
    public var path: URL
    public var hint: String?

    public init(
        shell: CompletionScripts.Shell, state: CompletionInstallState, path: URL,
        hint: String? = nil
    ) {
        self.shell = shell
        self.state = state
        self.path = path
        self.hint = hint
    }
}

public struct CLIToolStatus: Equatable, Sendable {
    public var directory: String
    public var linked: [String]
    public var missing: [String]
    public var onPath: Bool
    public var bundled: Bool

    public init(
        directory: String, linked: [String] = [], missing: [String] = [], onPath: Bool = false,
        bundled: Bool = false
    ) {
        self.directory = directory
        self.linked = linked
        self.missing = missing
        self.onPath = onPath
        self.bundled = bundled
    }

    public var isComplete: Bool { missing.isEmpty && !linked.isEmpty }
}

extension CLIInstaller {
    public static func status(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> CLIToolStatus {
        let target = preferredDirectory(home: home, fileManager: fileManager)
        var linked: [String] = []
        var missing: [String] = []
        for name in toolNames {
            let link = target.appendingPathComponent(name)
            if (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil
                || fileManager.isExecutableFile(atPath: link.path)
            {
                linked.append(name)
            } else {
                missing.append(name)
            }
        }
        return CLIToolStatus(
            directory: target.path, linked: linked, missing: missing,
            onPath: isOnPath(target, entries: pathEntries(environment)),
            bundled: bundledToolsDirectory(fileManager: fileManager) != nil)
    }
}

extension CompletionScripts {
    public static func existingFile(
        for shell: Shell, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        store: UserDefaults = SharedDefaults.store, fileManager: FileManager = .default
    ) -> URL? {
        var candidates: [URL] = []
        if let recorded = recordedPath(for: shell, store: store) { candidates.append(recorded) }
        candidates.append(
            defaultDirectory(for: shell, home: home).appendingPathComponent(shell.scriptName))
        candidates.append(
            installDirectory(for: shell, home: home).appendingPathComponent(shell.scriptName))
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    public static func status(
        for shell: Shell, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        store: UserDefaults = SharedDefaults.store, fileManager: FileManager = .default
    ) -> CompletionStatus {
        guard
            let file = existingFile(
                for: shell, home: home, store: store, fileManager: fileManager)
        else {
            let target = installDirectory(for: shell, home: home)
            return CompletionStatus(
                shell: shell, state: .missing,
                path: target.appendingPathComponent(shell.scriptName),
                hint: rcHint(for: shell, directory: target))
        }
        let text = String(
            decoding: fileManager.contents(atPath: file.path) ?? Data(), as: UTF8.self)
        let state: CompletionInstallState =
            !isOurs(text) ? .foreign : (text == contents(for: shell) ? .current : .outdated)
        return CompletionStatus(
            shell: shell, state: state, path: file,
            hint: rcHint(for: shell, directory: file.deletingLastPathComponent()))
    }

    public static func statuses(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        store: UserDefaults = SharedDefaults.store, fileManager: FileManager = .default
    ) -> [CompletionStatus] {
        detectShells(home: home, fileManager: fileManager).map {
            status(for: $0, home: home, store: store, fileManager: fileManager)
        }
    }
}
