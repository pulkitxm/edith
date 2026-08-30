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
        containerID: String, platform: RemoteMachinePlatform = .linux, using run: Run
    ) async -> Result<DockerInspectSummary, Error> {
        switch await run(DockerCommands.inspectRaw(containerID, platform: platform), 30) {
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
        containerID: String, platform: RemoteMachinePlatform = .linux, using run: Run
    ) async -> Result<[DockerProcess], Error> {
        switch await run(DockerCommands.top(containerID, platform: platform), 30) {
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
    public static func browserHost(
        for machine: Machine, configHosts: [SSHConfigHost]? = nil
    ) -> String? {
        let direct = machine.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case let .sshConfigAlias(alias) = machine.source else {
            return direct.isEmpty ? nil : direct
        }
        let configured = (configHosts ?? SSHConfigFile.concreteHosts()).first {
            $0.alias.compare(alias, options: .caseInsensitive) == .orderedSame
        }
        if let hostName = configured?.hostName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !hostName.isEmpty
        {
            return hostName
        }
        if !direct.isEmpty { return direct }
        return configured?.alias ?? alias
    }

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
        try selectedPort(
            from: publishedPorts(in: container, matching: requestedPort), in: container,
            matching: requestedPort)
    }

    public static func publishedPort(
        in container: DockerContainer, matching requestedPort: Int?, for machine: Machine,
        configHosts: [SSHConfigHost]? = nil
    ) throws -> DockerPortMapping {
        let reachable = reachablePorts(in: container, for: machine, configHosts: configHosts)
            .filter { port in
                guard let requestedPort else { return true }
                return port.hostPort == requestedPort || port.containerPort == requestedPort
            }
        let ports =
            reachable.isEmpty
            ? publishedPorts(in: container, matching: requestedPort) : reachable
        return try selectedPort(
            from: ports, in: container, matching: requestedPort,
            browserHost: browserHost(for: machine, configHosts: configHosts))
    }

    private static func selectedPort(
        from ports: [DockerPortMapping], in container: DockerContainer,
        matching requestedPort: Int?, browserHost: String? = nil
    ) throws -> DockerPortMapping {
        guard !ports.isEmpty else {
            throw MachineDetailOperationError.noPublishedPort(
                container.displayName, requestedPort)
        }
        guard ports.count == 1 else {
            if let binding = preferredBinding(in: ports, browserHost: browserHost) {
                return binding
            }
            throw MachineDetailOperationError.ambiguousPublishedPorts(
                container.displayName, ports.compactMap(\.hostPort))
        }
        return ports[0]
    }

    private static func preferredBinding(
        in ports: [DockerPortMapping], browserHost: String?
    ) -> DockerPortMapping? {
        guard let first = ports.first,
            ports.allSatisfy({
                $0.hostPort == first.hostPort && $0.containerPort == first.containerPort
                    && $0.proto == first.proto
            })
        else { return nil }
        let host = browserHost.map { unwrapped($0).lowercased() }
        let exact = ports.filter { port in
            guard let bind = port.hostIP else { return false }
            return unwrapped(bind).lowercased() == host
        }
        return (exact.isEmpty ? ports : exact).min { lhs, rhs in
            normalizedBinding(lhs.hostIP) < normalizedBinding(rhs.hostIP)
        }
    }

    private static func normalizedBinding(_ host: String?) -> String {
        guard let host else { return "" }
        return unwrapped(host.trimmingCharacters(in: .whitespacesAndNewlines)).lowercased()
    }

    public static func url(for port: DockerPortMapping, host: String = "localhost") -> URL? {
        url(for: port, host: host, allowsLoopback: nil)
    }

    public static func url(
        for port: DockerPortMapping, machine: Machine, configHosts: [SSHConfigHost]? = nil
    ) -> URL? {
        guard let host = browserHost(for: machine, configHosts: configHosts) else { return nil }
        return url(for: port, host: host, allowsLoopback: machine.id == Machine.localID)
    }

    public static func reachablePorts(
        in container: DockerContainer, for machine: Machine,
        configHosts: [SSHConfigHost]? = nil
    ) -> [DockerPortMapping] {
        guard let host = browserHost(for: machine, configHosts: configHosts) else { return [] }
        let allowsLoopback = machine.id == Machine.localID
        return container.ports.filter {
            url(for: $0, host: host, allowsLoopback: allowsLoopback) != nil
        }
    }

    private static func url(
        for port: DockerPortMapping, host: String, allowsLoopback: Bool?
    ) -> URL? {
        guard
            let hostPort = port.hostPort, port.proto == "tcp",
            let target = targetHost(
                bindAddress: port.hostIP, fallback: host, allowsLoopback: allowsLoopback)
        else { return nil }
        return url(host: target, port: hostPort)
    }

    private static func targetHost(
        bindAddress: String?, fallback: String, allowsLoopback: Bool? = nil
    ) -> String? {
        let fallback = unwrapped(fallback.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !fallback.isEmpty else { return nil }
        guard let bindAddress else { return fallback }
        let bind = unwrapped(bindAddress.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !bind.isEmpty, bind != "0.0.0.0", bind != "::" else { return fallback }
        guard !isLoopback(bind) || (allowsLoopback ?? isLoopback(fallback)) else { return nil }
        return bind
    }

    private static func url(host: String, port: Int) -> URL? {
        let normalized = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        var components = URLComponents()
        components.scheme = "http"
        components.host = normalized
        components.port = port
        return components.url
    }

    private static func unwrapped(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]") else { return host }
        return String(host.dropFirst().dropLast())
    }

    private static func isLoopback(_ host: String) -> Bool {
        let value = unwrapped(host).lowercased()
        return value == "localhost" || value == "::1" || value.hasPrefix("127.")
    }
}

public enum SavedSnippetOperationExecution {
    public static func snippet(
        at index: Int, in snippets: [CommandSnippet]
    ) throws -> CommandSnippet {
        guard index >= 1, index <= snippets.count else {
            throw MachineDetailOperationError.missingSnippet(index, snippets.count)
        }
        return snippets[index - 1]
    }

    public static func run<Output: Sendable>(
        _ snippet: CommandSnippet,
        using run: (String, TimeInterval) async -> Result<Output, Error>
    ) async -> Result<Output, Error> {
        await run(snippet.command, 120)
    }
}
