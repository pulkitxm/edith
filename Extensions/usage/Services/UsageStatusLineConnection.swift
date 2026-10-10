import EdithExtensionSupport
import Foundation

final class UsageStatusLineConnection: @unchecked Sendable {
    private struct OwnedHook: Codable {
        let command: String
        var suspended: Bool
    }

    private let settings: URL
    private let marker: URL
    private let executable: String?
    private let defaults: UserDefaults

    init(settings: URL, marker: URL, executable: String?, defaults: UserDefaults) {
        self.settings = settings
        self.marker = marker
        self.executable = executable
        self.defaults = defaults
    }

    func connect() throws -> ClaudeStatusLine.Change {
        try withLock { try install() }
    }

    func disconnect() throws -> ClaudeStatusLine.Change {
        try withLock {
            defaults.set(true, forKey: AppStorageKeys.Limits.claudeStatusLineOptOut)
            let change = try suspend()
            if FileManager.default.fileExists(atPath: marker.path) {
                try FileManager.default.removeItem(at: marker)
            }
            return change
        }
    }

    func suspendOwnedHook() throws {
        _ = try withLock { try suspend() }
    }

    func resumeOwnedHook() throws {
        try withLock {
            guard !ClaudeStatusLine.isOptedOut(defaults: defaults), let owned = try read() else {
                return
            }
            let current = try ClaudeStatusLine.configuredCommand(settings: settings)
            guard
                current == owned.command
                    || (owned.suspended
                        && current == ClaudeStatusLine.wrappedCommand(in: owned.command))
            else { return }
            _ = try install()
        }
    }

    private func install() throws -> ClaudeStatusLine.Change {
        guard let executable else { throw ClaudeStatusLine.Failure.missingExecutable }
        let original = try UsageDataFiles.readRegularFile(at: marker, maximumBytes: 524_288)
        let ownedCommand = original.flatMap { try? JSONDecoder().decode(OwnedHook.self, from: $0) }?
            .command
        do {
            let change = try ClaudeStatusLine.install(
                executable: executable, settings: settings, ownedCommand: ownedCommand
            ) {
                try self.write(OwnedHook(command: $0, suspended: false))
            }
            defaults.removeObject(forKey: AppStorageKeys.Limits.claudeStatusLineOptOut)
            return change
        } catch {
            if let original {
                try UsageDataFiles.write(original, to: marker)
            } else if FileManager.default.fileExists(atPath: marker.path) {
                try FileManager.default.removeItem(at: marker)
            }
            throw error
        }
    }

    private func suspend() throws -> ClaudeStatusLine.Change {
        guard var owned = try read(),
            try ClaudeStatusLine.configuredCommand(settings: settings) == owned.command
        else { return .absent }
        owned.suspended = true
        try write(owned)
        return try ClaudeStatusLine.remove(settings: settings)
    }

    private func read() throws -> OwnedHook? {
        guard let data = try UsageDataFiles.readRegularFile(at: marker, maximumBytes: 524_288)
        else { return nil }
        guard let owned = try? JSONDecoder().decode(OwnedHook.self, from: data),
            owned.command.utf8.count <= 262_144, ClaudeStatusLine.isRecorder(owned.command)
        else { throw ExtensionPeerError.invalidRequest }
        return owned
    }

    private func write(_ owned: OwnedHook) throws {
        guard owned.command.utf8.count <= 262_144 else { throw ExtensionPeerError.invalidRequest }
        let data = try JSONEncoder().encode(owned)
        guard data.count <= 524_288 else { throw ExtensionPeerError.invalidRequest }
        try UsageDataFiles.write(data, to: marker)
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let lock = try UsageDataLock.acquire(at: marker.appendingPathExtension("lock"))
        defer { lock.release() }
        return try body()
    }
}
