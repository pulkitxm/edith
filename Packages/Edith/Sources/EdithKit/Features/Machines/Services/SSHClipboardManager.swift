import Foundation

private final class SSHClipboardOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

public struct SSHClipboardPeerConfiguration: Codable, Equatable, Sendable {
    public var name: String
    public var sshCommand: String

    private enum CodingKeys: String, CodingKey {
        case name
        case sshCommand = "ssh_command"
    }

    public init(name: String, sshCommand: String) {
        self.name = name
        self.sshCommand = sshCommand
    }
}

public struct SSHClipboardConfiguration: Codable, Equatable, Sendable {
    public var version: UInt16
    public var nodeID: UUID
    public var nodeName: String
    public var peers: [SSHClipboardPeerConfiguration]
    public var maxBytes: UInt64
    public var pollIntervalMs: UInt64

    private enum CodingKeys: String, CodingKey {
        case version
        case nodeID = "node_id"
        case nodeName = "node_name"
        case peers
        case maxBytes = "max_bytes"
        case pollIntervalMs = "poll_interval_ms"
    }

    public init(
        version: UInt16 = 1, nodeID: UUID = UUID(),
        nodeName: String = ProcessInfo.processInfo.hostName,
        peers: [SSHClipboardPeerConfiguration] = [], maxBytes: UInt64 = 256 * 1024 * 1024,
        pollIntervalMs: UInt64 = 75
    ) {
        self.version = version
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.peers = peers
        self.maxBytes = maxBytes
        self.pollIntervalMs = pollIntervalMs
    }

    public static func decode(_ data: Data) throws -> SSHClipboardConfiguration {
        try JSONDecoder().decode(SSHClipboardConfiguration.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    public mutating func enable(_ machine: Machine, replacing previous: Machine? = nil) {
        if let previous {
            let command = Self.sshCommand(for: previous)
            peers.removeAll { $0.sshCommand == command }
        }
        let peer = SSHClipboardPeerConfiguration(
            name: machine.name, sshCommand: Self.sshCommand(for: machine))
        if let index = peers.firstIndex(where: { $0.sshCommand == peer.sshCommand }) {
            peers[index] = peer
        } else {
            peers.append(peer)
        }
    }

    public mutating func disable(_ machine: Machine) {
        let command = Self.sshCommand(for: machine)
        peers.removeAll { $0.sshCommand == command }
    }

    public static func sshCommand(for machine: Machine) -> String {
        switch machine.source {
        case let .sshConfigAlias(alias):
            return ShellQuote.command([SSHConnection.executable.path, alias])
        case .manual:
            var parts = [SSHConnection.executable.path]
            if machine.port != 22 { parts += ["-p", String(machine.port)] }
            parts.append(machine.sshTarget)
            return ShellQuote.command(parts)
        }
    }
}

public enum SSHClipboardManagerError: LocalizedError, Equatable {
    case unsupportedAuthentication
    case missingLocalExecutable
    case localCommandFailed(String)
    case remoteCommandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedAuthentication:
            return "Clipboard sync requires passwordless SSH through your SSH agent or SSH config."
        case .missingLocalExecutable:
            return "ssh-clipboard could not be installed because npm is unavailable."
        case let .localCommandFailed(message), let .remoteCommandFailed(message):
            return message
        }
    }
}

public actor SSHClipboardManager {
    public static let shared = SSHClipboardManager()
    public static let packageVersion = "0.2.8"

    private let configFile: URL
    private let homeDirectory: URL
    private let fileManager: FileManager

    public init(
        configFile: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.configFile =
            configFile
            ?? homeDirectory.appendingPathComponent(".config/ssh-clipboard/config.json")
    }

    public func reconcile(
        _ machine: Machine, replacing previous: Machine? = nil,
        connection suppliedConnection: SSHConnection? = nil
    ) async throws {
        if !machine.sshClipboardEnabled {
            try await disable(machine, replacing: previous)
            return
        }
        guard machine.auth == .agent else {
            throw SSHClipboardManagerError.unsupportedAuthentication
        }
        let ownsConnection = suppliedConnection == nil
        let connection = suppliedConnection ?? SSHConnection(machine: machine)
        do {
            try await connection.connect()
            try await installRemote(on: connection, machine: machine)
            if ownsConnection { await connection.disconnect() }
        } catch {
            if ownsConnection { await connection.disconnect() }
            throw error
        }
        var configuration = try loadConfiguration()
        configuration.enable(machine, replacing: previous)
        try save(configuration)
        let executable = try await resolveLocalExecutable()
        try await runLocal(executable, arguments: ["service", "install"])
        try await runLocal(executable, arguments: ["service", "restart"])
    }

    public func disable(_ machine: Machine, replacing previous: Machine? = nil) async throws {
        guard fileManager.fileExists(atPath: configFile.path) else { return }
        var configuration = try loadConfiguration()
        if let previous { configuration.disable(previous) }
        configuration.disable(machine)
        try save(configuration)
        guard let executable = existingLocalExecutable() else { return }
        try await runLocal(executable, arguments: ["service", "install"])
        try await runLocal(executable, arguments: ["service", "restart"])
    }

    private func loadConfiguration() throws -> SSHClipboardConfiguration {
        guard fileManager.fileExists(atPath: configFile.path) else {
            return SSHClipboardConfiguration()
        }
        return try SSHClipboardConfiguration.decode(Data(contentsOf: configFile))
    }

    private func save(_ configuration: SSHClipboardConfiguration) throws {
        let directory = configFile.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try configuration.encoded().write(to: configFile, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)
    }

    private func installRemote(on connection: SSHConnection, machine: Machine) async throws {
        let executable = "$HOME/.local/bin/ssh-clipboard"
        let version = Self.packageVersion
        let inspect = try await connection.run(
            "test -x \"\(executable)\" && \"\(executable)\" --version || true", timeout: 20)
        let expected = "ssh-clipboard \(version)"
        if inspect.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) != expected {
            let install = try await connection.run(
                "command -v npm >/dev/null 2>&1 && npm install --no-audit --no-fund --prefix \"$HOME/.local\" ssh-clipboard@\(version)",
                timeout: 180)
            guard install.succeeded else {
                throw SSHClipboardManagerError.remoteCommandFailed(
                    remoteFailure(
                        install, fallback: "Could not install ssh-clipboard on \(machine.name)."))
            }
        }
        let configPath = "$HOME/.config/ssh-clipboard/config.json"
        let existing = try await connection.run("test -f \"\(configPath)\"", timeout: 20)
        if !existing.succeeded {
            let remoteConfig = SSHClipboardConfiguration(nodeName: machine.name)
            let upload = try await connection.run(
                "umask 077; mkdir -p \"$HOME/.config/ssh-clipboard\"; cat > \"\(configPath)\"",
                stdin: try remoteConfig.encoded(), timeout: 30)
            guard upload.succeeded else {
                throw SSHClipboardManagerError.remoteCommandFailed(
                    remoteFailure(
                        upload, fallback: "Could not configure ssh-clipboard on \(machine.name)."))
            }
        }
        let service = try await connection.run(
            "\"\(executable)\" service install", timeout: 60)
        guard service.succeeded else {
            throw SSHClipboardManagerError.remoteCommandFailed(
                remoteFailure(
                    service, fallback: "Could not start ssh-clipboard on \(machine.name)."))
        }
    }

    private func resolveLocalExecutable() async throws -> URL {
        if let existing = existingLocalExecutable() { return existing }
        guard let npm = npmExecutable() else {
            throw SSHClipboardManagerError.missingLocalExecutable
        }
        try await runLocal(
            npm,
            arguments: [
                "install", "--no-audit", "--no-fund", "--prefix",
                homeDirectory.appendingPathComponent(".local").path,
                "ssh-clipboard@\(Self.packageVersion)",
            ])
        guard let installed = existingLocalExecutable() else {
            throw SSHClipboardManagerError.missingLocalExecutable
        }
        return installed
    }

    private func existingLocalExecutable() -> URL? {
        let candidates = [
            homeDirectory.appendingPathComponent(".local/bin/ssh-clipboard"),
            URL(fileURLWithPath: "/opt/homebrew/bin/ssh-clipboard"),
            URL(fileURLWithPath: "/usr/local/bin/ssh-clipboard"),
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func npmExecutable() -> URL? {
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/npm"),
            URL(fileURLWithPath: "/usr/local/bin/npm"),
            URL(fileURLWithPath: "/usr/bin/npm"),
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func runLocal(_ executable: URL, arguments: [String]) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let error = Pipe()
        let stdoutBuffer = SSHClipboardOutputBuffer()
        let stderrBuffer = SSHClipboardOutputBuffer()
        process.standardOutput = output
        process.standardError = error
        output.fileHandleForReading.readabilityHandler = {
            stdoutBuffer.append($0.availableData)
        }
        error.fileHandleForReading.readabilityHandler = {
            stderrBuffer.append($0.availableData)
        }
        try process.run()
        let status = await SSHConnection.waitForExit(process, timeout: 180)
        output.fileHandleForReading.readabilityHandler = nil
        error.fileHandleForReading.readabilityHandler = nil
        stdoutBuffer.append(output.fileHandleForReading.readDataToEndOfFile())
        stderrBuffer.append(error.fileHandleForReading.readDataToEndOfFile())
        let stdout = stdoutBuffer.snapshot()
        let stderr = stderrBuffer.snapshot()
        guard status == 0 else {
            let detail = String(decoding: stderr.isEmpty ? stdout : stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHClipboardManagerError.localCommandFailed(
                detail.isEmpty
                    ? "\(executable.lastPathComponent) exited with status \(status)." : detail)
        }
    }

    private func remoteFailure(_ result: SSHExecResult, fallback: String) -> String {
        let detail = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? fallback : detail
    }
}
