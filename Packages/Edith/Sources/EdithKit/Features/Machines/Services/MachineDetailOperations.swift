import EdithCore
import Foundation

public enum DockerDetailOperation: String, CaseIterable, Sendable {
    case inspect
    case top

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "machines.docker.\(rawValue)"),
            summary: rawValue == "inspect" ? "Inspect a container." : "Read container processes.",
            cli: ["machines", "docker", rawValue], effect: .read)
    }
}

public enum SavedSnippetOperation: CaseIterable, Sendable {
    case run

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "machines.snippets.run"),
            summary: "Run a saved command on a machine.",
            cli: ["machines", "snippets", "run"], effect: .interactive)
    }
}

public enum MachineDetailOperationError: LocalizedError, Equatable {
    case invalidInspect(String)
    case invalidProcesses(String)
    case missingContainer(String)
    case noPublishedPort(String, Int?)
    case ambiguousPublishedPorts(String, [Int])
    case missingSnippet(Int, Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidInspect(container):
            return "Docker returned an invalid inspect result for \(container)."
        case let .invalidProcesses(container):
            return "Docker returned an invalid process list for \(container)."
        case let .missingContainer(container):
            return "No container named \(container) was found."
        case let .noPublishedPort(container, requested):
            if let requested {
                return "\(container) has no published TCP port matching \(requested)."
            }
            return "\(container) has no published TCP port."
        case let .ambiguousPublishedPorts(container, ports):
            return
                "\(container) has multiple published ports: \(ports.map(String.init).joined(separator: ", "))."
        case let .missingSnippet(index, count):
            return "There is no snippet \(index). This machine offers \(count), numbered from 1."
        }
    }
}

public enum DockerDetailOperationExecution {
    public typealias Run = (String, TimeInterval) async -> Result<String, Error>

    public static func inspect(
        containerID: String, using run: Run
    ) async -> Result<DockerInspectSummary, Error> {
        switch await run(DockerCommands.inspectRaw(containerID), 30) {
        case let .success(output):
            guard let summary = DockerParsing.inspectSummary(output) else {
                return .failure(MachineDetailOperationError.invalidInspect(containerID))
            }
            return .success(summary)
        case let .failure(error):
            return .failure(error)
        }
    }

    public static func processes(
        containerID: String, using run: Run
    ) async -> Result<[DockerProcess], Error> {
        switch await run(DockerCommands.top(containerID), 30) {
        case let .success(output):
            let processes = DockerParsing.processes(output)
            guard !processes.isEmpty else {
                return .failure(MachineDetailOperationError.invalidProcesses(containerID))
            }
            return .success(processes)
        case let .failure(error):
            return .failure(error)
        }
    }
}

public enum DockerBrowserOperationExecution {
    public static func container(
        named query: String, in containers: [DockerContainer]
    ) throws -> DockerContainer {
        guard
            let container = containers.first(where: {
                $0.id == query || $0.shortID == query || $0.names.contains(query)
            })
        else { throw MachineDetailOperationError.missingContainer(query) }
        return container
    }

    public static func publishedPorts(
        in container: DockerContainer, matching requestedPort: Int?
    ) -> [DockerPortMapping] {
        container.ports.filter { port in
            guard url(for: port) != nil else { return false }
            guard let requestedPort else { return true }
            return port.hostPort == requestedPort || port.containerPort == requestedPort
        }
    }

    public static func publishedPort(
        in container: DockerContainer, matching requestedPort: Int?
    ) throws -> DockerPortMapping {
        let ports = publishedPorts(in: container, matching: requestedPort)
        guard !ports.isEmpty else {
            throw MachineDetailOperationError.noPublishedPort(
                container.displayName, requestedPort)
        }
        guard ports.count == 1 else {
            throw MachineDetailOperationError.ambiguousPublishedPorts(
                container.displayName, ports.compactMap(\.hostPort))
        }
        return ports[0]
    }

    public static func url(for port: DockerPortMapping, host: String = "localhost") -> URL? {
        guard let hostPort = port.hostPort, port.proto == "tcp" else { return nil }
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized =
            trimmed.contains(":") && !trimmed.hasPrefix("[") ? "[\(trimmed)]" : trimmed
        var components = URLComponents()
        components.scheme = "http"
        components.host = normalized
        components.port = hostPort
        return components.url
    }
}

public enum SavedSnippetOperationExecution {
    public typealias Run = (String, TimeInterval) async -> Result<String, Error>

    public static func snippet(
        at index: Int, in snippets: [CommandSnippet]
    ) throws -> CommandSnippet {
        guard index >= 1, index <= snippets.count else {
            throw MachineDetailOperationError.missingSnippet(index, snippets.count)
        }
        return snippets[index - 1]
    }

    public static func run(
        _ snippet: CommandSnippet, using run: Run
    ) async -> Result<String, Error> {
        await run(snippet.command, 120)
    }
}
