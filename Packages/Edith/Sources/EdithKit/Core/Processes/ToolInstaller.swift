import Foundation

public enum ToolInstallFailure: Error, CustomStringConvertible, Equatable {
    case noPackageManager(String)
    case commandFailed(String, Int32)
    case unverified(String)

    public var description: String {
        switch self {
        case let .noPackageManager(name):
            return "Neither Homebrew nor npm is available for installing \(name)."
        case let .commandFailed(command, status):
            return "\(command) exited with status \(status)."
        case let .unverified(name):
            return "Installation finished, but \(name) could not be verified."
        }
    }
}

public struct ToolInstaller: Sendable {
    public typealias RunCommand =
        @Sendable (CLICommandRequest, @escaping @Sendable (String) -> Void) async throws ->
        CLICommandResult

    public typealias Log = @Sendable (String) -> Void

    private let runCommand: RunCommand

    public init(
        runCommand: @escaping RunCommand = { try await CLICommandRunner.run($0, onLine: $1) }
    ) {
        self.runCommand = runCommand
    }

    public func detectedVersion(of tool: CLIToolSpec, log: @escaping Log = { _ in }) async
        -> String?
    {
        let name: String
        let arguments: [String]
        switch tool.presenceStrategy {
        case let .executable(executableName, versionArguments):
            name = executableName
            arguments = [executableName] + versionArguments
        }
        guard let result = try? await run(env(arguments), log: log),
            result.terminationStatus == 0
        else { return nil }
        let version = result.output.components(separatedBy: .newlines).first {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.trimmingCharacters(in: .whitespacesAndNewlines)
        return version ?? name
    }

    @discardableResult
    public func install(_ tool: CLIToolSpec, log: @escaping Log = { _ in }) async throws -> String {
        switch tool.installStrategy {
        case let .standaloneBinary(url, destinationName, _):
            try await installStandaloneBinary(
                url: url, destinationName: destinationName, log: log)
        case let .packageManagers(homebrewArguments, npmPackage, _):
            try await installPackage(
                homebrewArguments: homebrewArguments, npmPackage: npmPackage,
                displayName: tool.displayName, log: log)
        }
        guard let version = await detectedVersion(of: tool, log: log) else {
            throw ToolInstallFailure.unverified(tool.displayName)
        }
        return version
    }

    private func installStandaloneBinary(
        url: URL, destinationName: String, log: @escaping Log
    ) async throws {
        let binDirectory = AppData.supportDir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(
            at: binDirectory, withIntermediateDirectories: true)
        let destination = binDirectory.appendingPathComponent(destinationName)
        let temporary = binDirectory.appendingPathComponent(
            ".\(destinationName)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        log("Downloading " + url.absoluteString)
        try await requireSuccess(
            CLICommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/curl"),
                arguments: [
                    "--fail", "--location", "--progress-bar", url.absoluteString, "--output",
                    temporary.path,
                ], environment: CLIToolEnvironment.sanitized()), named: "curl", log: log)
        try await requireSuccess(
            CLICommandRequest(
                executableURL: URL(fileURLWithPath: "/bin/chmod"),
                arguments: ["+x", temporary.path],
                environment: CLIToolEnvironment.sanitized()), named: "chmod", log: log)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        log("Saved " + destination.path)
    }

    private func installPackage(
        homebrewArguments: [String], npmPackage: String, displayName: String,
        log: @escaping Log
    ) async throws {
        if await isPresent("brew", log: log) {
            log("Running brew " + homebrewArguments.joined(separator: " "))
            let result = try await run(env(["brew"] + homebrewArguments), log: log)
            if result.terminationStatus == 0 { return }
            log("Homebrew install failed, trying npm.")
        } else {
            log("Homebrew was not found, checking npm.")
        }
        guard await isPresent("npm", log: log) else {
            throw ToolInstallFailure.noPackageManager(displayName)
        }
        log("Running npm install -g " + npmPackage)
        try await requireSuccess(
            env(["npm", "install", "-g", npmPackage]), named: "npm", log: log)
    }

    private func isPresent(_ name: String, log: @escaping Log) async -> Bool {
        guard let result = try? await run(env([name, "--version"]), log: log) else { return false }
        return result.terminationStatus == 0
    }

    private func requireSuccess(
        _ request: CLICommandRequest, named: String, log: @escaping Log
    ) async throws {
        let result = try await run(request, log: log)
        guard result.terminationStatus == 0 else {
            throw ToolInstallFailure.commandFailed(named, result.terminationStatus)
        }
    }

    private func env(_ arguments: [String]) -> CLICommandRequest {
        CLICommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: arguments,
            environment: CLIToolEnvironment.sanitized())
    }

    private func run(_ request: CLICommandRequest, log: @escaping Log) async throws
        -> CLICommandResult
    {
        try await runCommand(request, log)
    }
}
