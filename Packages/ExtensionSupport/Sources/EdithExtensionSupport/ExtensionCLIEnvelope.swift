import Foundation

public struct ExtensionCLIRequest: Codable, Equatable, Sendable {
    public let arguments: [String]
    public init(arguments: [String]) throws {
        guard arguments.count <= 128,
            arguments.allSatisfy({ $0.utf8.count <= 4_096 && !$0.utf8.contains(0) }),
            arguments.reduce(0, { $0 + $1.utf8.count }) <= 16_384
        else { throw ExtensionPeerError.invalidRequest }
        self.arguments = arguments
    }

    public func validate() throws { _ = try Self(arguments: arguments) }
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
