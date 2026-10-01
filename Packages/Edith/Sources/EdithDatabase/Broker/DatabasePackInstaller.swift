import CryptoKit
import EdithCore
import Foundation
import Security

public enum DatabasePackInstallError: Error, Equatable, Sendable {
    case checksumMismatch
    case signatureRejected
    case signatureUnavailable
    case archiveInvalid
    case downloadFailed
    case developmentBuild
}

public enum DatabasePackRelease {
    public static let archiveName = "edith-database.zip"
    public static let checksumName = "edith-database.zip.sha256"
    public static let repository = "pulkitxm/edith"

    public static func archiveURL(version: String) -> URL? {
        endpoint(version: version, name: archiveName)
    }

    public static func checksumURL(version: String) -> URL? {
        endpoint(version: version, name: checksumName)
    }

    private static func endpoint(version: String, name: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(repository)/releases/download/v\(version)/\(name)"
        return components.url
    }
}

enum DatabasePackChecksum {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func matches(_ data: Data, digest: String) -> Bool {
        sha256Hex(data) == digest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func digest(in text: String) -> String? {
        let token = text.split { !$0.isHexDigit }.first { $0.count == 64 }
        return token.map { String($0).lowercased() }
    }
}

enum DatabasePackArchive {
    static func extractExecutable(from archive: Data, to destination: URL) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "edith-database-zip-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let zip = root.appendingPathComponent("pack.zip")
        try archive.write(to: zip, options: .atomic)
        let extracted = root.appendingPathComponent("out", isDirectory: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", zip.path, extracted.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let executable = findExecutable(in: extracted) else {
            throw DatabasePackInstallError.archiveInvalid
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: executable, to: destination)
    }

    private static func findExecutable(in directory: URL) -> URL? {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: nil)
        else { return nil }
        for case let url as URL in enumerator
        where url.lastPathComponent == DatabasePackIdentity.executableName {
            return url
        }
        return nil
    }
}

enum DatabasePackHTTP {
    static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("Edith", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw DatabasePackInstallError.downloadFailed
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DatabasePackInstallError.downloadFailed
        }
        return data
    }
}

struct LiveDatabasePackSignatureChecker {
    func validate(executableAt path: String, requirement: String) throws {
        var code: SecStaticCode?
        guard
            SecStaticCodeCreateWithPath(
                URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
            let code
        else { throw DatabasePackInstallError.signatureUnavailable }
        var parsed: SecRequirement?
        guard
            SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess,
            let parsed
        else { throw DatabasePackInstallError.signatureUnavailable }
        guard SecStaticCodeCheckValidity(code, [], parsed) == errSecSuccess else {
            throw DatabasePackInstallError.signatureRejected
        }
    }

    static func teamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard
            SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
            let staticCode
        else { return nil }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard
            SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
            let information = information as? [String: Any]
        else { return nil }
        guard
            let team = information[kSecCodeInfoTeamIdentifier as String] as? String,
            !team.isEmpty
        else { return nil }
        return team
    }
}

public struct DatabasePackInstaller: Sendable {
    public var directories: AppDirectories
    public var expectedVersion: String
    public var requirement: String
    public var allowsDownload: Bool
    public var fetch: @Sendable (URL) async throws -> Data
    public var extract: @Sendable (Data, URL) throws -> Void
    public var validateSignature: @Sendable (String, String) throws -> Void
    public var progress: @Sendable (Double) -> Void

    public static func live(
        directories: AppDirectories = .current,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) -> DatabasePackInstaller {
        let identifier = AppBuildIdentity.application + DatabasePackIdentity.suffix
        let team = LiveDatabasePackSignatureChecker.teamIdentifier()
        return DatabasePackInstaller(
            directories: directories,
            expectedVersion: DatabasePackVersion.current(),
            requirement: DatabasePackIdentity.requirement(
                identifier: identifier, teamIdentifier: team),
            allowsDownload: !AppBuildIdentity.isDevelopment,
            fetch: { url in
                try await DatabasePackHTTP.fetch(url)
            },
            extract: { archive, destination in
                try DatabasePackArchive.extractExecutable(from: archive, to: destination)
            },
            validateSignature: { path, requirement in
                try LiveDatabasePackSignatureChecker().validate(
                    executableAt: path, requirement: requirement)
            },
            progress: progress)
    }

    public func install() async throws -> DatabasePackInspection {
        let current = DatabasePackStore.inspect(
            expectedVersion: expectedVersion, directories: directories)
        if current.state == .current { return current }
        guard allowsDownload else {
            if current.state == .mismatched || current.state == .invalid {
                try DatabasePackStore.remove(directories: directories)
            }
            throw DatabasePackInstallError.developmentBuild
        }
        guard
            let checksumURL = DatabasePackRelease.checksumURL(version: expectedVersion),
            let archiveURL = DatabasePackRelease.archiveURL(version: expectedVersion)
        else { throw DatabasePackInstallError.downloadFailed }
        progress(0.05)
        let checksumText: String
        let archive: Data
        do {
            let checksumData = try await fetch(checksumURL)
            guard let text = String(data: checksumData, encoding: .utf8) else {
                throw DatabasePackInstallError.checksumMismatch
            }
            checksumText = text
            progress(0.2)
            archive = try await fetch(archiveURL)
        } catch let error as DatabasePackInstallError {
            throw error
        } catch {
            throw DatabasePackInstallError.downloadFailed
        }
        guard
            let digest = DatabasePackChecksum.digest(in: checksumText),
            DatabasePackChecksum.matches(archive, digest: digest)
        else { throw DatabasePackInstallError.checksumMismatch }
        progress(0.75)
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory.appendingPathComponent(
            "edith-database-pack-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent(DatabasePackIdentity.executableName)
        try extract(archive, executable)
        do {
            try validateSignature(executable.path, requirement)
        } catch let error as DatabasePackInstallError {
            throw error
        } catch {
            throw DatabasePackInstallError.signatureRejected
        }
        progress(0.9)
        try DatabasePackStore.install(
            executable: executable, version: expectedVersion, directories: directories)
        progress(1)
        return DatabasePackStore.inspect(
            expectedVersion: expectedVersion, directories: directories)
    }
}
