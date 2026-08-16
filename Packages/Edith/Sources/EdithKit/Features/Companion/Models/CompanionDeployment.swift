import Foundation

public struct CompanionDeployment: Codable, Equatable, Sendable {
    public static let projectName = "edith-companion"
    public static let defaultRemoteDirectory = "~/edith-companion"
    public static let apiPort = 4820

    public var machineID: UUID?
    public var machineName: String
    public var directory: String
    public var tier: String
    public var localPort: Int
    public var forwardID: UUID?
    public var deployedAt: Date

    public init(
        machineID: UUID?, machineName: String, directory: String = defaultRemoteDirectory,
        tier: String, localPort: Int = apiPort, forwardID: UUID? = nil,
        deployedAt: Date = Date()
    ) {
        self.machineID = machineID
        self.machineName = machineName
        self.directory = directory
        self.tier = tier
        self.localPort = localPort
        self.forwardID = forwardID
        self.deployedAt = deployedAt
    }

    public var isLocal: Bool { machineID == nil }

    public var endpoint: URL {
        URL(string: "http://127.0.0.1:\(localPort)") ?? URL(string: "http://127.0.0.1:4820")!
    }

    public var plainEnglish: String {
        isLocal
            ? "running on this Mac, \(tier)"
            : "running on \(machineName), \(tier), reached on port \(localPort)"
    }
}

public enum CompanionTier: String, CaseIterable, Codable, Sendable {
    case gpu
    case cpu
    case appleMetal

    public var composeFiles: [String] {
        switch self {
        case .gpu: ["compose.yaml", "compose.gpu.yaml"]
        case .cpu: ["compose.yaml", "compose.cpu.yaml"]
        case .appleMetal: ["compose.yaml", "compose.mac.yaml"]
        }
    }

    public var displayName: String {
        switch self {
        case .gpu: "GPU"
        case .cpu: "CPU only"
        case .appleMetal: "Apple Metal"
        }
    }

    public static func derive(from facts: CompanionHostFacts) -> CompanionTier {
        if facts.os == "darwin" { return .appleMetal }
        if let gpu = facts.gpuModel, !gpu.isEmpty { return .gpu }
        return .cpu
    }
}

public enum CompanionDeploymentStore {
    public static var file: URL {
        MachinePaths.root.appendingPathComponent("companion-deployment.json")
    }

    public static func load(_ url: URL = file) -> CompanionDeployment? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CompanionDeployment.self, from: data)
    }

    @discardableResult
    public static func save(_ deployment: CompanionDeployment, to url: URL = file)
        -> CompanionDeployment
    {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(deployment) else { return deployment }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        return deployment
    }

    public static func clear(_ url: URL = file) {
        try? FileManager.default.removeItem(at: url)
    }
}

public enum CompanionStackCommands {
    public static func quoteDirectory(_ directory: String) -> String {
        guard directory == "~" || directory.hasPrefix("~/") else {
            return ShellQuote.quote(directory)
        }
        let rest = String(directory.dropFirst(directory == "~" ? 1 : 2))
        return rest.isEmpty ? "\"$HOME\"" : "\"$HOME\"/" + ShellQuote.quote(rest)
    }

    public static func compose(
        _ action: String, directory: String, tier: CompanionTier,
        project: String = CompanionDeployment.projectName
    ) -> String {
        let files = tier.composeFiles.map { "-f \(ShellQuote.quote($0))" }.joined(separator: " ")
        return "cd \(quoteDirectory(directory)) && docker compose \(files) "
            + "-p \(ShellQuote.quote(project)) \(action)"
    }

    public static func up(directory: String, tier: CompanionTier, build: Bool) -> String {
        compose(build ? "up -d --build" : "up -d", directory: directory, tier: tier)
    }

    public static func down(directory: String, tier: CompanionTier, keepData: Bool) -> String {
        compose(keepData ? "down" : "down -v", directory: directory, tier: tier)
    }

    public static func restart(directory: String, tier: CompanionTier) -> String {
        compose("restart", directory: directory, tier: tier)
    }

    public static func ps(directory: String, tier: CompanionTier) -> String {
        compose(
            "ps --format \(ShellQuote.quote("{{.Service}}\t{{.Status}}\t{{.Ports}}"))",
            directory: directory, tier: tier)
    }

    public static func logs(
        directory: String, tier: CompanionTier, service: String?, tail: Int
    ) -> String {
        var action = "logs --no-color --tail \(tail)"
        if let service, !service.isEmpty { action += " \(ShellQuote.quote(service))" }
        return compose(action, directory: directory, tier: tier)
    }

    public static func makeDirectory(_ directory: String) -> String {
        "mkdir -p \(quoteDirectory(directory))"
    }

    public static func writeFile(_ path: String, directory: String) -> String {
        "cat > \(quoteDirectory(directory))/\(ShellQuote.quote(path))"
    }

    public static func health(port: Int = CompanionDeployment.apiPort) -> String {
        "curl -fsS -m 10 http://127.0.0.1:\(port)/v1/health"
    }
}

public struct CompanionServiceStatus: Equatable, Sendable {
    public let service: String
    public let status: String
    public let ports: String

    public init(service: String, status: String, ports: String) {
        self.service = service
        self.status = status
        self.ports = ports
    }

    public var running: Bool { status.hasPrefix("Up") }
}

public enum CompanionStackParsing {
    public static func services(_ output: String) -> [CompanionServiceStatus] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2, !parts[0].isEmpty, parts[0] != "SERVICE" else { return nil }
            return CompanionServiceStatus(
                service: parts[0].trimmingCharacters(in: .whitespaces),
                status: parts[1].trimmingCharacters(in: .whitespaces),
                ports: parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : "")
        }
    }
}
