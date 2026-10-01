import EdithCore
import Foundation

public struct DatabasePackInspection: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case missing
        case current
        case mismatched
        case invalid
    }

    public var state: State
    public var installedVersion: String?
    public var expectedVersion: String
    public var path: String

    public init(
        state: State,
        installedVersion: String?,
        expectedVersion: String,
        path: String
    ) {
        self.state = state
        self.installedVersion = installedVersion
        self.expectedVersion = expectedVersion
        self.path = path
    }
}

public enum DatabasePackVersion {
    public static func current(info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        guard
            let value = info?["CFBundleShortVersionString"] as? String
        else { return "development" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "development" : trimmed
    }
}

public enum DatabasePackStore {
    public static let versionFileName = "version"

    public static func inspect(
        expectedVersion: String,
        directories: AppDirectories = .current,
        fileManager: FileManager = .default
    ) -> DatabasePackInspection {
        let executable = DatabasePackIdentity.executableURL(in: directories)
        let versionURL = DatabasePackIdentity.directory(in: directories)
            .appendingPathComponent(versionFileName)
        guard fileManager.fileExists(atPath: executable.path) else {
            return DatabasePackInspection(
                state: .missing,
                installedVersion: nil,
                expectedVersion: expectedVersion,
                path: executable.path)
        }
        guard
            let text = try? String(contentsOf: versionURL, encoding: .utf8)
        else {
            return DatabasePackInspection(
                state: .invalid,
                installedVersion: nil,
                expectedVersion: expectedVersion,
                path: executable.path)
        }
        let installed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !installed.isEmpty else {
            return DatabasePackInspection(
                state: .invalid,
                installedVersion: nil,
                expectedVersion: expectedVersion,
                path: executable.path)
        }
        return DatabasePackInspection(
            state: installed == expectedVersion ? .current : .mismatched,
            installedVersion: installed,
            expectedVersion: expectedVersion,
            path: executable.path)
    }

    public static func install(
        executable: URL,
        version: String,
        directories: AppDirectories = .current,
        fileManager: FileManager = .default
    ) throws {
        let directory = DatabasePackIdentity.directory(in: directories)
        let parent = directory.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            "pack.staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let stagedExecutable = staging.appendingPathComponent(DatabasePackIdentity.executableName)
        do {
            try fileManager.copyItem(at: executable, to: stagedExecutable)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: stagedExecutable.path)
            try (version + "\n").write(
                to: staging.appendingPathComponent(versionFileName),
                atomically: true,
                encoding: .utf8)
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
            try fileManager.moveItem(at: staging, to: directory)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    @discardableResult
    public static func remove(
        directories: AppDirectories = .current,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let directory = DatabasePackIdentity.directory(in: directories)
        guard fileManager.fileExists(atPath: directory.path) else { return false }
        try fileManager.removeItem(at: directory)
        return true
    }
}
