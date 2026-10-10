import EdithExtensionSupport
import Foundation

public struct HostCoreOwnerCatalog: Codable, Sendable {
    public struct Agent: Codable, Sendable {
        public let jobs: String
        public let run: String?
        public let cancel: String?
        public let events: String?
        public let logs: String?
    }
    public struct Readiness: Codable, Sendable {
        public let inspect: String
        public let setup: String?
    }
    public let version: Int
    public let owner: String
    public let agent: Agent?
    public let readiness: Readiness?
    public let routes: [HostCLIProviderCommand]?
    public let parserHelp: HostCLIJSON?
    public let completionOperation: String?

    public static func decode(_ data: Data, owner: String) throws -> Self? {
        try HostCLIProviderCatalog.decode(data, owner: owner).coreOwner
    }

    public func validate(owner expected: String) throws {
        guard version == 1, owner == expected,
            agent != nil || readiness != nil || !(routes ?? []).isEmpty
        else { throw HostCLIError.rejected("Invalid core owner catalog.") }
        if let agent {
            guard agent.jobs == owner + ".agent.jobs",
                agent.run == nil || agent.run == owner + ".agent.run",
                agent.cancel == nil || agent.cancel == owner + ".agent.cancel",
                agent.events == nil || agent.events == owner + ".agent.events",
                agent.logs == nil || agent.logs == owner + ".agent.logs"
            else { throw HostCLIError.rejected("Invalid owning agent operations.") }
        }
        if let readiness {
            guard readiness.inspect == owner + ".lifecycle.inspect",
                readiness.setup == nil || readiness.setup == owner + ".lifecycle.setup"
            else { throw HostCLIError.rejected("Invalid owning readiness operations.") }
        }
        if let completionOperation, completionOperation != owner + ".agent.complete" {
            throw HostCLIError.rejected("Invalid original agent completion operation.")
        }
        let routes = routes ?? []
        guard routes.count <= 128, Set(routes.map(\.route)).count == routes.count else {
            throw HostCLIError.rejected("Invalid owning agent routes.")
        }
        if let parserHelp {
            guard parserHelp.object?["serializationVersion"] == .integer(0),
                let command = parserHelp.object?["command"],
                command.object?["commandName"] == .string("agent"),
                try parserHelp.encoded().count <= 1_048_576
            else {
                throw HostCLIError.rejected("Invalid original agent parser catalog.")
            }
            try HostCLIProviderCatalog.validateHelp(command, route: [], commands: routes)
        }
        for route in routes {
            let domains =
                owner == "herdr" ? ["tasks", "schedule"] : owner == "usage" ? ["activity"] : []
            guard (2...12).contains(route.route.count), route.route[0] == "agent",
                domains.contains(route.route[1]),
                route.route.dropFirst().allSatisfy({
                    !$0.isEmpty && $0.utf8.count <= 128
                        && $0.utf8.allSatisfy {
                            (48...57).contains($0) || (65...90).contains($0)
                                || (97...122).contains($0)
                                || $0 == 45 || $0 == 46 || $0 == 95
                        }
                }), route.operation == owner + ".agent.cli", route.timeout.isFinite,
                (1...120).contains(route.timeout), route.readsInput != true,
                HostCoreReadinessReport.text(route.summary)
            else { throw HostCLIError.rejected("Invalid original agent route owner.") }
            if let stream = route.streamOperation {
                guard stream == owner + ".agent.cli", let deadline = route.streamDeadline,
                    deadline.isFinite, (1...21600).contains(deadline)
                else { throw HostCLIError.rejected("Invalid original agent stream.") }
            } else if route.streamDeadline != nil {
                throw HostCLIError.rejected("Missing original agent stream.")
            }
        }
    }
}

public struct HostCoreOwnerRegistry: Sendable {
    public struct Provider: Sendable {
        public let state: HostCLIProviderState
        public let catalog: HostCoreOwnerCatalog
        public let identity: ExtensionProcessIdentity
    }
    public let states: [HostCLIProviderState]
    public let providers: [Provider]
    public let issues: [String: String]
    private let invoke: HostCLIProviderRegistry.Invoke

    public static func load(invoke: @escaping HostCLIProviderRegistry.Invoke) async throws -> Self {
        let states = try await HostCLIProviderRegistry.states(invoke: invoke)
        var providers: [Provider] = []
        var issues: [String: String] = [:]
        let selected = states.filter {
            $0.available && HostCLIProviderCatalog.prefixes[$0.id] != nil
        }
        await withTaskGroup(of: (HostCLIProviderState, HostCoreOwnerCatalog?, String?).self) {
            group in
            var iterator = selected.makeIterator()
            func add(_ state: HostCLIProviderState) {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let data = try await invoke(
                            HostCLIRequest(
                                action: .invoke, id: state.id,
                                operation: state.id + ".cli.catalog", timeout: 2))
                        return (state, try HostCoreOwnerCatalog.decode(data, owner: state.id), nil)
                    } catch { return (state, nil, error.localizedDescription) }
                }
            }
            for _ in 0..<8 { if let state = iterator.next() { add(state) } }
            for await (state, catalog, error) in group {
                if let catalog, let pid = state.processIdentifier,
                    let identity = ExtensionProcessIdentity.read(pid), identity.isAlive
                {
                    providers.append(Provider(state: state, catalog: catalog, identity: identity))
                } else {
                    issues[state.id] = error ?? "The owner has not supplied its typed core hooks."
                }
                if let state = iterator.next() { add(state) }
            }
        }
        try Task.checkCancellation()
        let current = try await HostCLIProviderRegistry.states(invoke: invoke)
        providers.removeAll { provider in
            if current.contains(provider.state) { return false }
            issues[provider.state.id] = "The owner changed during discovery."; return true
        }
        return Self(
            states: current, providers: providers.sorted { $0.state.id < $1.state.id },
            issues: issues, invoke: invoke)
    }

    public func call<T: Decodable>(
        _ type: T.Type, provider: Provider, operation: String,
        payload: Data = Data("{}".utf8), timeout: Double = 30
    ) async throws -> T {
        guard provider.identity.isAlive,
            ExtensionProcessIdentity.read(provider.identity.pid) == provider.identity,
            try await HostCLIProviderRegistry.states(invoke: invoke).contains(provider.state)
        else {
            throw HostCoreCommandFailure(
                "The owning extension changed or was disabled.",
                hint: "Retry after checking ed extensions status " + provider.state.id)
        }
        let data = try await invoke(
            HostCLIRequest(
                action: .invoke, id: provider.state.id,
                operation: operation, payload: payload, timeout: timeout))
        try Task.checkCancellation()
        guard provider.identity.isAlive,
            ExtensionProcessIdentity.read(provider.identity.pid) == provider.identity,
            try await HostCLIProviderRegistry.states(invoke: invoke).contains(provider.state),
            data.count <= HostCLIRequest.maximumPayload
        else {
            throw HostCoreCommandFailure(
                "The owning extension changed before its result arrived.",
                hint: "Retry after checking ed extensions status " + provider.state.id)
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
