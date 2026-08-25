import Darwin
import EdithKit
import Foundation
import Security

enum ClaudeCredentialSource: Equatable {
    case keychain
    case file(URL)
    case shell
}

struct ClaudeOAuthCredential {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let refreshTokenExpiresAt: Date?
    let source: ClaudeCredentialSource
    private let document: [String: Any]

    static func decode(_ data: Data, source: ClaudeCredentialSource) -> ClaudeOAuthCredential? {
        guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = document["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String,
            !accessToken.isEmpty
        else { return nil }
        return ClaudeOAuthCredential(
            accessToken: accessToken,
            refreshToken: nonempty(oauth["refreshToken"] as? String),
            expiresAt: millisecondsDate(oauth["expiresAt"]),
            refreshTokenExpiresAt: millisecondsDate(oauth["refreshTokenExpiresAt"]),
            source: source,
            document: document)
    }

    static func transient(accessToken: String, maximumBytes: Int = 8_192)
        -> ClaudeOAuthCredential?
    {
        guard !accessToken.isEmpty, accessToken.utf8.count <= maximumBytes,
            accessToken.unicodeScalars.allSatisfy({ 0x21...0x7E ~= $0.value })
        else { return nil }
        return ClaudeOAuthCredential(
            accessToken: accessToken,
            refreshToken: nil,
            expiresAt: nil,
            refreshTokenExpiresAt: nil,
            source: .shell,
            document: [:])
    }

    func shouldRefresh(at now: Date, leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(leeway)
    }

    func usableRefreshToken(at now: Date) -> String? {
        guard let refreshToken else { return nil }
        if let refreshTokenExpiresAt, refreshTokenExpiresAt <= now { return nil }
        return refreshToken
    }

    func updatedData(with response: ClaudeOAuthRefreshResponse, now: Date) throws -> Data {
        var updated = document
        var oauth = updated["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = response.accessToken
        oauth["expiresAt"] = Int64(
            now.addingTimeInterval(response.expiresIn).timeIntervalSince1970 * 1000)
        if let refreshToken = response.refreshToken, !refreshToken.isEmpty {
            oauth["refreshToken"] = refreshToken
        }
        if let refreshTokenExpiresIn = response.refreshTokenExpiresIn {
            oauth["refreshTokenExpiresAt"] = Int64(
                now.addingTimeInterval(refreshTokenExpiresIn).timeIntervalSince1970 * 1000)
        }
        updated["claudeAiOauth"] = oauth
        return try JSONSerialization.data(withJSONObject: updated)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func millisecondsDate(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue / 1000)
    }
}

struct ClaudeOAuthRefreshResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: TimeInterval
    let refreshTokenExpiresIn: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case refreshTokenExpiresIn = "refresh_token_expires_in"
    }
}

enum ClaudeCredentialStoreError: LocalizedError, Equatable {
    case keychainUpdateFailed
    case transientCredential

    var errorDescription: String? {
        switch self {
        case .keychainUpdateFailed:
            return "Keychain update failed"
        case .transientCredential:
            return "Transient credentials cannot be persisted"
        }
    }
}

enum ClaudeCredentialDataLookup: Equatable {
    case data(Data)
    case missing
    case cancelled
    case timedOut
    case oversized
    case failed
}

enum ClaudeCredentialStore {
    typealias CommandRunner = @Sendable (CLICommandRequest) async throws -> CLICommandResult

    private static let keychainService = "Claude Code-credentials"
    private static let securityURL = URL(fileURLWithPath: "/usr/bin/security")
    private static let processTimeout: TimeInterval = 3
    private static let maximumCredentialBytes = 65_536
    private static let maximumStatusBytes = 1_024
    private static let itemNotFoundExitStatus = Int32(
        UInt8(truncatingIfNeeded: errSecItemNotFound))

    static func read() async -> ClaudeCredentialLookup {
        let keychain = await keychainData(
            securityExecutable: securityURL, timeout: processTimeout,
            maximumOutputBytes: maximumCredentialBytes,
            runCommand: { request in
                try await CLICommandRunner.run(request) { _ in }
            })
        return read(
            home: FileManager.default.homeDirectoryForCurrentUser,
            keychainData: keychain,
            fileData: { credentialFileData(at: $0) })
    }

    static func read(
        home: URL,
        keychainData: ClaudeCredentialDataLookup,
        fileData: (URL) -> ClaudeCredentialDataLookup
    ) -> ClaudeCredentialLookup {
        let keychainFailure: ClaudeCredentialLookupFailure?
        switch keychainData {
        case .data(let data):
            if let credential = ClaudeOAuthCredential.decode(data, source: .keychain) {
                return .credential(credential)
            }
            keychainFailure = .malformed
        case .missing:
            keychainFailure = nil
        case .cancelled:
            return .cancelled
        case .timedOut:
            keychainFailure = .timedOut
        case .oversized:
            keychainFailure = .oversized
        case .failed:
            keychainFailure = .failed
        }
        let url = home.appendingPathComponent(".claude/.credentials.json")
        switch fileData(url) {
        case .data(let data):
            guard let credential = ClaudeOAuthCredential.decode(data, source: .file(url)) else {
                return .failure(.malformed)
            }
            return .credential(credential)
        case .missing:
            return .failure(keychainFailure ?? .missing)
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .failure(.timedOut)
        case .oversized:
            return .failure(.oversized)
        case .failed:
            return .failure(.failed)
        }
    }

    static func persist(
        _ data: Data, source: ClaudeCredentialSource,
        securityExecutable: URL = securityURL, timeout: TimeInterval = processTimeout,
        maximumOutputBytes: Int = maximumStatusBytes,
        runCommand: @escaping CommandRunner = { request in
            try await CLICommandRunner.run(request) { _ in }
        }
    ) async throws {
        switch source {
        case .keychain:
            guard data.count <= maximumCredentialBytes else {
                throw ClaudeCredentialStoreError.keychainUpdateFailed
            }
            try await updateKeychain(
                data, securityExecutable: securityExecutable, timeout: timeout,
                maximumOutputBytes: maximumOutputBytes, runCommand: runCommand)
        case .file(let url):
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        case .shell:
            throw ClaudeCredentialStoreError.transientCredential
        }
    }

    static func keychainData(
        securityExecutable: URL, timeout: TimeInterval, maximumOutputBytes: Int,
        runCommand: @escaping CommandRunner = { request in
            try await CLICommandRunner.run(request) { _ in }
        }
    ) async -> ClaudeCredentialDataLookup {
        let request = securityRequest(
            executable: securityExecutable,
            arguments: ["find-generic-password", "-s", keychainService, "-w"],
            timeout: timeout, maximumOutputBytes: maximumOutputBytes)
        do {
            let result = try await runCommand(request)
            switch result.terminationStatus {
            case 0:
                return .data(result.outputData)
            case itemNotFoundExitStatus:
                return .missing
            default:
                return .failed
            }
        } catch is CancellationError {
            return .cancelled
        } catch CLICommandRunnerError.timedOut {
            return .timedOut
        } catch CLICommandRunnerError.outputLimitExceeded {
            return .oversized
        } catch {
            return .failed
        }
    }

    static func credentialFileData(
        at url: URL, maximumOutputBytes: Int = maximumCredentialBytes
    ) -> ClaudeCredentialDataLookup {
        guard maximumOutputBytes >= 0, maximumOutputBytes < Int.max else { return .failed }
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else { return errno == ENOENT ? .missing : .failed }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        do {
            defer { try? handle.close() }
            guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
                return .failed
            }
            let data = try handle.read(upToCount: maximumOutputBytes + 1) ?? Data()
            guard data.count <= maximumOutputBytes else { return .oversized }
            return .data(data)
        } catch {
            return .failed
        }
    }

    private static func updateKeychain(
        _ data: Data, securityExecutable: URL, timeout: TimeInterval,
        maximumOutputBytes: Int, runCommand: @escaping CommandRunner
    ) async throws {
        var input = data
        input.append(UInt8(ascii: "\n"))
        input.append(data)
        input.append(UInt8(ascii: "\n"))
        let request = securityRequest(
            executable: securityExecutable,
            arguments: [
                "add-generic-password", "-U", "-a", NSUserName(), "-s", keychainService, "-w",
            ], timeout: timeout, maximumOutputBytes: maximumOutputBytes, standardInputData: input)
        do {
            let result = try await runCommand(request)
            guard result.terminationStatus == 0 else {
                throw ClaudeCredentialStoreError.keychainUpdateFailed
            }
        } catch {
            throw ClaudeCredentialStoreError.keychainUpdateFailed
        }
    }

    private static func securityRequest(
        executable: URL, arguments: [String], timeout: TimeInterval,
        maximumOutputBytes: Int, standardInputData: Data? = nil
    ) -> CLICommandRequest {
        let username = NSUserName()
        return CLICommandRequest(
            executableURL: executable,
            arguments: arguments,
            environment: [
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "LANG": "en_US.UTF-8",
                "LOGNAME": username,
                "PATH": "/usr/bin:/bin",
                "USER": username,
            ],
            currentDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes,
            standardInputData: standardInputData,
            discardsStandardError: true,
            terminatesProcessGroup: true)
    }
}
