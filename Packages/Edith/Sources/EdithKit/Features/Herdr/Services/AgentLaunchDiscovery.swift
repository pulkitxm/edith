import Foundation

public enum AgentLaunchDiscovery {
    public typealias Fetch = @Sendable (AgentLaunchKind, Bool, Machine?) async -> String?

    static let pathPrefix =
        "$HOME/.local/bin:$HOME/.opencode/bin:$HOME/.cargo/bin:$HOME/.bun/bin:"
        + "/opt/homebrew/bin:/usr/local/bin:$PATH"
    static let maximumOutputBytes = 4_000_000

    public static func timeout(refresh: Bool) -> TimeInterval { refresh ? 20 : 8 }

    public static func script(
        for kind: AgentLaunchKind, refresh: Bool, platform: RemoteMachinePlatform
    ) -> String? {
        let body: String
        switch kind {
        case .codex:
            let cache = #"c="${CODEX_HOME:-$HOME/.codex}/models_cache.json"; "#
            let cached = #"{ [ -s "$c" ] && cat "$c"; }"#
            body =
                refresh
                ? cache + "codex debug models || \(cached) || codex debug models --bundled"
                : cache + "\(cached) || codex debug models --bundled"
        case .opencode:
            body =
                platform == .linux
                ? "script -qec 'opencode models' /dev/null"
                : "script -q /dev/null opencode models"
        case .pi:
            body = "pi --list-models"
        case .cursor:
            body =
                "if command -v cursor-agent >/dev/null 2>&1; then cursor-agent models; "
                + "else agent models; fi"
        case .claude, .gemini, .amp:
            return nil
        }
        return "export PATH=\"\(pathPrefix)\" NO_COLOR=1; { \(body); } </dev/null 2>/dev/null "
            + "| head -c \(maximumOutputBytes)"
    }

    public static let live: Fetch = { kind, refresh, machine in
        if let machine { return await remote(kind, refresh: refresh, on: machine) }
        return await local(kind, refresh: refresh)
    }

    private static func local(_ kind: AgentLaunchKind, refresh: Bool) async -> String? {
        guard let script = script(for: kind, refresh: refresh, platform: .darwin) else {
            return nil
        }
        let request = CLICommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
            environment: CLIToolEnvironment.sanitized(), timeout: timeout(refresh: refresh),
            maximumOutputBytes: maximumOutputBytes + 1_024, discardsStandardError: true,
            terminatesProcessGroup: true)
        guard let result = try? await CLICommandRunner.run(request, onLine: { _ in }) else {
            return nil
        }
        return result.standardOutput
    }

    private static func remote(_ kind: AgentLaunchKind, refresh: Bool, on machine: Machine) async
        -> String?
    {
        let connection = SSHConnection(machine: machine, controlSocketMode: .shared)
        guard (try? await connection.connect()) != nil else { return nil }
        let platform = await connection.remotePlatform ?? .linux
        guard platform != .windows,
            let script = script(for: kind, refresh: refresh, platform: platform)
        else { return nil }
        let result = try? await connection.run(
            "/bin/sh -c " + ShellQuote.quote(script), timeout: timeout(refresh: refresh))
        return result?.stdoutText
    }
}

public actor AgentLaunchCatalogs {
    public static let shared = AgentLaunchCatalogs()

    private let fetch: AgentLaunchDiscovery.Fetch
    private let lifetime: TimeInterval
    private let clock: @Sendable () -> Date
    private var entries: [String: (catalog: AgentLaunchCatalog, stored: Date)] = [:]
    private var inFlight: [String: Task<String?, Never>] = [:]

    public init(
        lifetime: TimeInterval = 600, clock: @escaping @Sendable () -> Date = { Date() },
        fetch: @escaping AgentLaunchDiscovery.Fetch = AgentLaunchDiscovery.live
    ) {
        self.lifetime = lifetime
        self.clock = clock
        self.fetch = fetch
    }

    public func catalog(
        for kind: AgentLaunchKind, on machine: Machine? = nil, refresh: Bool = false
    ) async -> AgentLaunchCatalog {
        guard kind.discoveryCommand != nil else { return kind.builtIn }
        let key = Self.key(kind, machine)
        if !refresh, let entry = entries[key], clock().timeIntervalSince(entry.stored) < lifetime {
            return entry.catalog
        }
        let flight = "\(key)|\(refresh)"
        let fetch = fetch
        let task = inFlight[flight] ?? Task { await fetch(kind, refresh, machine) }
        inFlight[flight] = task
        let output = await task.value
        if inFlight[flight] == task { inFlight[flight] = nil }
        let catalog = output.flatMap { AgentLaunchCatalogParser.catalog(kind, from: $0) }
        let resolved = catalog ?? kind.builtIn
        entries[key] = (resolved, clock())
        return resolved
    }

    public func cached(for kind: AgentLaunchKind, on machine: Machine? = nil) -> AgentLaunchCatalog
    {
        entries[Self.key(kind, machine)]?.catalog ?? kind.builtIn
    }

    private static func key(_ kind: AgentLaunchKind, _ machine: Machine?) -> String {
        "\(machine?.id.uuidString ?? "local")|\(kind.rawValue)"
    }
}
