import Darwin
import Foundation

public struct HostRequirementToolSpec: Equatable, Sendable {
    public let id: String
    public let executable: String
    public let arguments: [String]
    public static let all: [Self] = [
        .init(id: "homebrew", executable: "brew", arguments: ["--version"]),
        .init(id: "yt-dlp", executable: "yt-dlp", arguments: ["--version"]),
        .init(id: "gallery-dl", executable: "gallery-dl", arguments: ["--version"]),
        .init(id: "ffmpeg", executable: "ffmpeg", arguments: ["-version"]),
        .init(id: "qpdf", executable: "qpdf", arguments: ["--version"]),
        .init(id: "deno", executable: "deno", arguments: ["--version"]),
        .init(id: "claude", executable: "claude", arguments: ["--version"]),
        .init(id: "codex", executable: "codex", arguments: ["--version"]),
        .init(id: "latexmk", executable: "latexmk", arguments: ["-v"]),
        .init(id: "tectonic", executable: "tectonic", arguments: ["--version"]),
        .init(id: "pukbot", executable: "pukbot", arguments: ["--version"]),
        .init(id: "quinjet", executable: "quinjet", arguments: ["--version"]),
        .init(id: "git", executable: "git", arguments: ["--version"]),
        .init(id: "gh", executable: "gh", arguments: ["--version"]),
        .init(id: "node", executable: "node", arguments: ["--version"]),
        .init(id: "npx", executable: "npx", arguments: ["--version"]),
    ]
}

@MainActor public struct HostRequirementToolProbe {
    public struct Output: Equatable, Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
    }
    public typealias Run = (URL, [String]) async throws -> Output
    private let directories: [URL]
    private let run: Run
    public init(directories: [URL], run: Run? = nil) {
        self.directories = directories
        self.run =
            run ?? { try await Self.execute($0, arguments: $1, searchDirectories: directories) }
    }

    public func inspect(id: String) async throws -> HostRequirementObservation {
        guard let spec = HostRequirementToolSpec.all.first(where: { $0.id == id }) else {
            throw HostCLIError.usage("Unknown requirement tool: " + id)
        }
        try Task.checkCancellation()
        guard
            let executable = directories.filter({ $0.isFileURL && $0.path.hasPrefix("/") })
                .map({ $0.appendingPathComponent(spec.executable) })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
        else {
            return .missing(spec.executable + " is not in the explicit executable search path.")
        }
        do {
            let output = try await run(executable, spec.arguments)
            try Task.checkCancellation()
            guard output.status == 0,
                let version = Self.version(in: output.stdout + "\n" + output.stderr)
            else { return .failed(spec.executable + " was found, but its version probe failed.") }
            if id == "node", !Self.nodeSupported(version) {
                return .unsupported(
                    "Plugins installation requires Node.js 22.20 or later. Found " + version
                        + ". Browsing remains available.")
            }
            return .available(version)
        } catch is CancellationError { throw CancellationError() } catch {
            return .failed(
                spec.executable + " version inspection failed: "
                    + String(error.localizedDescription.prefix(512)))
        }
    }

    static func version(in text: String) -> String? {
        guard
            let range = text.range(
                of: "[0-9]+(?:\\.[0-9]+){1,3}(?:[-+][A-Za-z0-9.-]+)?", options: .regularExpression)
        else { return nil }
        return String(text[range])
    }

    static func nodeSupported(_ version: String) -> Bool {
        guard !version.contains("-") else { return false }
        let parts = version.split(separator: ".").prefix(2).compactMap { Int($0) }
        return parts.count == 2 && (parts[0] > 22 || parts[0] == 22 && parts[1] >= 20)
    }

    public static func execute(
        _ executable: URL, arguments: [String], timeout: Duration = .seconds(5),
        maximumOutputBytes: Int = 32_768, searchDirectories: [URL] = []
    ) async throws -> Output {
        guard executable.isFileURL, arguments.count <= 16, maximumOutputBytes > 0,
            maximumOutputBytes <= 65_536, timeout > .zero, timeout <= .seconds(30),
            searchDirectories.count <= 64,
            searchDirectories.allSatisfy({
                $0.isFileURL && $0.path.hasPrefix("/") && !$0.path.contains(":")
            })
        else { throw HostCLIError.rejected("Invalid readonly executable probe bounds.") }
        try Task.checkCancellation()
        let process = Process()
        let stdout = Pipe(); let stderr = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.environment = [
            "PATH": (searchDirectories.map(\.path) + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
                .joined(separator: ":"),
            "LANG": "C", "LC_ALL": "C",
            "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1", "NO_UPDATE_NOTIFIER": "1",
            "npm_config_update_notifier": "false", "npm_config_offline": "true",
            "HOME": "/var/empty", "XDG_CONFIG_HOME": "/var/empty",
            "npm_config_userconfig": "/dev/null", "npm_config_globalconfig": "/dev/null",
            "npm_config_cache": "/dev/null", "npm_config_audit": "false",
            "npm_config_fund": "false",
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: "/var/empty")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout; process.standardError = stderr
        let descriptors = [
            stdout.fileHandleForReading.fileDescriptor, stderr.fileHandleForReading.fileDescriptor,
        ]
        for descriptor in descriptors {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw HostCLIError.rejected("Could not configure readonly executable probe.")
            }
        }
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
        }
        try process.run()
        try stdout.fileHandleForWriting.close(); try stderr.fileHandleForWriting.close()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var data = [Data(), Data()]
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw HostCLIError.rejected("Readonly version probe timed out.")
            }
            for (index, descriptor) in descriptors.enumerated() {
                while true {
                    let count = read(descriptor, &buffer, buffer.count)
                    if count > 0 {
                        guard data[0].count + data[1].count + count <= maximumOutputBytes else {
                            throw HostCLIError.rejected(
                                "Readonly version probe exceeded its output limit.")
                        }
                        data[index].append(contentsOf: buffer.prefix(count))
                    } else if count == -1 && errno == EINTR {
                        continue
                    } else if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK {
                        throw HostCLIError.rejected("Readonly version probe output failed.")
                    } else {
                        break
                    }
                }
            }
            if !process.isRunning {
                return Output(
                    status: process.terminationStatus,
                    stdout: String(decoding: data[0], as: UTF8.self),
                    stderr: String(decoding: data[1], as: UTF8.self))
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

public enum HostRequirementPlatform {
    public static func macOS(capability: String, version: OperatingSystemVersion)
        -> HostRequirementObservation
    {
        let known = Set(
            HostExtensionRequirementCatalog.entries.flatMap {
                ($0.original?.requiredCapabilities ?? [])
                    + ($0.original?.optionalCapabilities ?? [])
            })
        guard known.contains(capability) else {
            return .unsupported("No original platform implementation for " + capability + ".")
        }
        if version.majorVersion < 14 {
            return .unsupported("This host requires macOS 14 or later.")
        }
        if capability == "applicationAudio", version.majorVersion == 14, version.minorVersion < 4 {
            return .unsupported("Application audio mixing requires macOS 14.4 or later.")
        }
        if capability == "screenTimeLapse", version.majorVersion < 15 {
            return .unsupported("Screen recording requires macOS 15 or later.")
        }
        return .available(
            "The original platform capability is supported; permissions are checked separately.")
    }
}
