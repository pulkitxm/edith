import EdithExtensionSupport
import Foundation

@MainActor final class UsageCLIHookOwner {
    private let directory: URL
    private let defaults: UserDefaults
    private let executable: String?
    private var stopped = false
    private var settings: Set<String> = []
    private var restored = false

    init(
        directory: URL = Repo.dataDir, defaults: UserDefaults = SharedDefaults.store,
        executable: String? = nil
    ) {
        self.directory = directory
        self.defaults = defaults
        self.executable = executable
    }

    func connect(settings url: URL) throws -> ClaudeStatusLine.Change {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        try restore()
        try validate(url.path)
        guard settings.contains(url.path) || settings.count < 32 else {
            throw ExtensionPeerError.rejected("Too many status line settings files are connected.")
        }
        settings.insert(url.path)
        try save()
        return try connection(url).connect()
    }

    func disconnect(settings url: URL) throws -> ClaudeStatusLine.Change {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        try restore()
        try validate(url.path)
        let result = try connection(url).disconnect()
        settings.remove(url.path)
        try save()
        return result
    }

    func resumeOwnedHooks() throws {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        try restore()
        for path in settings.sorted() {
            try Task.checkCancellation()
            try connection(URL(fileURLWithPath: path)).resumeOwnedHook()
        }
    }

    func shutdown() throws {
        stopped = true
        try restore()
        var failure: Error?
        for path in settings.sorted() {
            do { try connection(URL(fileURLWithPath: path)).suspendOwnedHook() } catch {
                if failure == nil { failure = error }
            }
        }
        if let failure { throw failure }
    }

    private var registry: URL { directory.appendingPathComponent("cli-statusline-settings.json") }

    private func restore() throws {
        guard !restored else { return }
        if let data = try UsageDataFiles.readRegularFile(at: registry, maximumBytes: 262_144) {
            let paths = try JSONDecoder().decode([String].self, from: data)
            guard paths.count <= 32 else { throw ExtensionPeerError.invalidRequest }
            for path in paths { try validate(path) }
            settings = Set(paths)
        }
        restored = true
    }

    private func save() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try UsageDataFiles.write(JSONEncoder().encode(settings.sorted()), to: registry)
    }

    private func validate(_ path: String) throws {
        guard path.hasPrefix("/"), path.utf8.count <= 4_096, !path.utf8.contains(0) else {
            throw ExtensionPeerError.invalidRequest
        }
    }

    private func connection(_ url: URL) -> UsageStatusLineConnection {
        let marker: URL
        if url.standardizedFileURL == ClaudeStatusLine.settingsURL().standardizedFileURL {
            marker = directory.appendingPathComponent("claude-statusline-connection.json")
        } else {
            let identifier = UsageMachinesPeer.hash(Data(url.path.utf8))
            marker = directory.appendingPathComponent("cli-statusline-" + identifier + ".json")
        }
        return UsageStatusLineConnection(
            settings: url, marker: marker, executable: executable, defaults: defaults)
    }
}
