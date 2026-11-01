import Foundation

public struct ExtensionCLIRequest: Codable, Equatable, Sendable {
    public static let maximumInputBytes = 4 * 1_024 * 1_024
    public let arguments: [String]
    public let standardInput: Data
    public let workingDirectory: String
    public let interactive: Bool

    public init(
        arguments: [String], standardInput: Data = Data(),
        workingDirectory: String = "/", interactive: Bool = false
    ) throws {
        guard arguments.count <= 128,
            arguments.allSatisfy({ $0.utf8.count <= 4_096 && !$0.utf8.contains(0) }),
            arguments.reduce(0, { $0 + $1.utf8.count }) <= 16_384
        else { throw ExtensionPeerError.invalidRequest }
        guard standardInput.count <= Self.maximumInputBytes,
            workingDirectory.hasPrefix("/"), workingDirectory.utf8.count <= 4_096,
            !workingDirectory.utf8.contains(0)
        else { throw ExtensionPeerError.invalidRequest }
        self.arguments = arguments
        self.standardInput = standardInput
        self.workingDirectory = workingDirectory
        self.interactive = interactive
    }

    public func validate() throws {
        _ = try Self(
            arguments: arguments, standardInput: standardInput,
            workingDirectory: workingDirectory, interactive: interactive)
    }
}

public struct ExtensionCLIReply: Codable, Equatable, Sendable {
    public static let maximumOutputBytes = 4 * 1_024 * 1_024
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) throws {
        guard stdout.utf8.count + stderr.utf8.count <= Self.maximumOutputBytes,
            (0...255).contains(exitCode)
        else { throw ExtensionPeerError.invalidRequest }
        self.stdout = stdout; self.stderr = stderr; self.exitCode = exitCode
    }

    public func validate() throws {
        _ = try Self(stdout: stdout, stderr: stderr, exitCode: exitCode)
    }
}
