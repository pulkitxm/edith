import EdithCore
import EdithKit
import Foundation

public struct OperationMCPTool: Equatable, Sendable {
    public let name: String
    public let title: String
    public let summary: String
    public let route: [String]
    public let effect: UserOperationEffect
    public let requiresPreview: Bool

    public init(descriptor: UserOperationDescriptor) {
        name = OperationMCPCatalog.toolName(for: descriptor.cli)
        title = descriptor.cli.joined(separator: " ")
        summary = descriptor.summary
        route = descriptor.cli
        effect = descriptor.effect
        requiresPreview = descriptor.requiresPreview
    }

    public var isDestructive: Bool { effect == .destructive || requiresPreview }

    public func arguments(_ extra: [String], confirm: Bool) -> [String] {
        var result = route + extra
        if !result.contains("--json") { result.append("--json") }
        if isDestructive, confirm, !result.contains("--yes") { result.append("--yes") }
        return result
    }
}

public enum OperationMCPCatalog {
    public static let prefix = "edith_"

    public static func toolName(for route: [String]) -> String {
        prefix
            + route.joined(separator: "_")
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: ".", with: "_")
    }

    public static var tools: [OperationMCPTool] {
        var seen = Set<String>()
        return UserOperationCatalog.descriptors
            .filter { !$0.cli.isEmpty }
            .map(OperationMCPTool.init(descriptor:))
            .filter { seen.insert($0.name).inserted }
            .sorted { $0.name < $1.name }
    }

    public static func tool(named name: String) -> OperationMCPTool? {
        tools.first { $0.name == name }
    }

    public static func executableURL(
        bundle: Bundle = .main, fileManager: FileManager = .default
    ) -> URL? {
        let candidates = [
            URL(fileURLWithPath: CommandLine.arguments.first ?? ""),
            CLIInstaller.preferredDirectory().appendingPathComponent(CLIInstaller.primaryTool),
        ]
        return candidates.first {
            !$0.path.isEmpty && fileManager.isExecutableFile(atPath: $0.path)
        }
    }
}

public struct OperationMCPInvocation: Equatable, Sendable {
    public let output: String
    public let failed: Bool

    public init(output: String, failed: Bool) {
        self.output = output
        self.failed = failed
    }
}

public enum OperationMCPRunner {
    public static func run(
        _ tool: OperationMCPTool, arguments: [String], confirm: Bool,
        executable: URL? = OperationMCPCatalog.executableURL()
    ) -> OperationMCPInvocation {
        guard let executable else {
            return OperationMCPInvocation(
                output: "The ed executable could not be located.", failed: true)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = tool.arguments(arguments, confirm: confirm)
        let out = Pipe()
        let error = Pipe()
        process.standardOutput = out
        process.standardError = error
        guard (try? process.run()) != nil else {
            return OperationMCPInvocation(output: "ed could not be started.", failed: true)
        }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: stdout, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = String(data: stderr, encoding: .utf8) ?? ""
            return OperationMCPInvocation(
                output: detail.isEmpty ? text : detail, failed: true)
        }
        return OperationMCPInvocation(output: text, failed: false)
    }
}
