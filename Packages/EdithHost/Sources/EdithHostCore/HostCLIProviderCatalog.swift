import EdithExtensionSupport
import Foundation

public indirect enum HostCLIJSON: Codable, Sendable, Equatable {
    case null, bool(Bool), integer(Int64), number(Double), string(String)
    case array([HostCLIJSON]), object([String: HostCLIJSON])

    public init(from decoder: Decoder) throws {
        guard decoder.codingPath.count <= 32 else {
            throw HostCLIError.rejected("JSON is too deep.")
        }
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let bool = try? value.decode(Bool.self) {
            self = .bool(bool)
        } else if let integer = try? value.decode(Int64.self) {
            self = .integer(integer)
        } else if let number = try? value.decode(Double.self), number.isFinite {
            self = .number(number)
        } else if let string = try? value.decode(String.self) {
            self = .string(string)
        } else if let array = try? value.decode([Self].self) {
            self = .array(array)
        } else {
            self = .object(try value.decode([String: Self].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let item): try value.encode(item)
        case .integer(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public var object: [String: Self]? { if case .object(let value) = self { value } else { nil } }
    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var array: [Self]? { if case .array(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var integer: Int64? { if case .integer(let value) = self { value } else { nil } }
    public static func strings(_ values: [String]) -> Self { .array(values.map(Self.string)) }
}

public struct HostCLIProviderCommand: Codable, Equatable, Sendable {
    public let route: [String]
    public let operation: String
    public let summary: String
    public let destructive: Bool
    public let timeout: Double
    public let streamOperation: String?
    public let streamDeadline: Double?

    public var toolName: String {
        "edith_"
            + route.joined(separator: "_").replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: ".", with: "_")
    }

    public init(
        route: [String], operation: String, summary: String, destructive: Bool = false,
        timeout: Double = 30, streamOperation: String? = nil, streamDeadline: Double? = nil
    ) {
        self.route = route; self.operation = operation; self.summary = summary
        self.destructive = destructive; self.timeout = timeout
        self.streamOperation = streamOperation; self.streamDeadline = streamDeadline
    }
}

public struct HostCLIProviderCatalog: Codable, Sendable {
    public let version: Int
    public let owner: String
    public let commands: [HostCLIProviderCommand]
    public let settings: [HostCLISetting]
    public let acceptsInput: Bool?
    public let nativeTools: [HostCLINativeTool]?
    public let completionOperation: String?
    public let machineAliases: [String]?
    public let aliasOperation: String?

    public init(
        owner: String, commands: [HostCLIProviderCommand], settings: [HostCLISetting] = [],
        acceptsInput: Bool = false, nativeTools: [HostCLINativeTool] = [],
        completionOperation: String? = nil, machineAliases: [String] = [],
        aliasOperation: String? = nil
    ) {
        version = 1; self.owner = owner; self.commands = commands; self.settings = settings
        self.acceptsInput = acceptsInput
        self.nativeTools = nativeTools; self.completionOperation = completionOperation
        self.machineAliases = machineAliases; self.aliasOperation = aliasOperation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        owner = try container.decode(String.self, forKey: .owner)
        commands = try container.decode([HostCLIProviderCommand].self, forKey: .commands)
        settings = try container.decodeIfPresent([HostCLISetting].self, forKey: .settings) ?? []
        acceptsInput = try container.decodeIfPresent(Bool.self, forKey: .acceptsInput)
        nativeTools = try container.decodeIfPresent([HostCLINativeTool].self, forKey: .nativeTools)
        completionOperation = try container.decodeIfPresent(
            String.self, forKey: .completionOperation)
        machineAliases = try container.decodeIfPresent([String].self, forKey: .machineAliases)
        aliasOperation = try container.decodeIfPresent(String.self, forKey: .aliasOperation)
    }

    public static func decode(_ data: Data, owner: String) throws -> Self {
        guard data.count <= HostCLIRequest.maximumPayload else {
            throw HostCLIError.rejected("The command catalog exceeds its limit.")
        }
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        try catalog.validate(owner: owner)
        return catalog
    }

    public func validate(owner expected: String) throws {
        guard version == 1, owner == expected, let prefixes = Self.prefixes[owner],
            !commands.isEmpty || !(nativeTools ?? []).isEmpty || !settings.isEmpty,
            commands.count <= 1024,
            settings.count <= 512,
            Set(commands.map(\.toolName)).count == commands.count,
            Set(settings.map(\.key)).count == settings.count
        else { throw HostCLIError.rejected("Invalid extension command catalog.") }
        for command in commands {
            guard (1...12).contains(command.route.count),
                command.route.first.map(prefixes.contains) == true,
                command.route.allSatisfy(Self.word),
                !command.summary.isEmpty, command.summary.utf8.count <= 4096,
                !command.summary.utf8.contains(0), command.timeout.isFinite,
                (1...120).contains(command.timeout)
            else { throw HostCLIError.rejected("Invalid extension command route.") }
            _ = try HostCLIRequest(action: .invoke, id: owner, operation: command.operation)
            if let stream = command.streamOperation {
                _ = try HostCLIRequest(action: .invoke, id: owner, operation: stream + ".start")
                guard let deadline = command.streamDeadline, deadline.isFinite,
                    (1...21600).contains(deadline)
                else { throw HostCLIError.rejected("Invalid stream deadline.") }
            } else if command.streamDeadline != nil {
                throw HostCLIError.rejected("Missing stream operation.")
            }
        }
        for setting in settings { try setting.validate() }
        let tools = nativeTools ?? []
        guard tools.count <= 1024,
            Set(tools.map(\.name) + commands.map(\.toolName)).count == tools.count + commands.count
        else { throw HostCLIError.rejected("Duplicate tool names.") }
        for tool in tools { try tool.validate(owner: owner) }
        if let completionOperation {
            _ = try HostCLIRequest(action: .invoke, id: owner, operation: completionOperation)
        }
        let aliases = machineAliases ?? []
        guard aliases.count <= 128, Set(aliases).count == aliases.count,
            aliases.allSatisfy({ alias in
                Self.word(alias) && !Self.prefixes.values.contains { $0.contains(alias) }
                    && ![
                        "guide", "schema", "version", "status", "completions", "install",
                        "uninstall", "config", "app", "permissions", "extensions", "invoke", "mcp",
                    ].contains(alias)
            })
        else { throw HostCLIError.rejected("Invalid machine aliases.") }
        if !aliases.isEmpty {
            guard owner == "machines", let aliasOperation else {
                throw HostCLIError.rejected("Missing machine alias operation.")
            }
            _ = try HostCLIRequest(action: .invoke, id: owner, operation: aliasOperation)
        }
    }

    private static func word(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 80
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || [45, 46, 95].contains($0)
            }
    }

    public static let prefixes: [String: Set<String>] = [
        "host": ["config", "app", "permissions"],
        "keepAwake": [], "focusDim": [], "windowSweaters": [], "keystrokeHighlight": [],
        "micMute": [], "blitztree": [], "timeLapse": [], "terminal": [],
        "calendar": ["calendar"], "music": ["music"], "usage": ["usage"],
        "machines": ["machines"], "herdr": ["herdr"], "quinjet": ["quinjet"],
        "studio": ["studio"], "database": ["database"], "docs": ["docs"],
        "latex": ["latex"], "companion": ["companion"], "bifrost": ["bifrost"],
        "plugins": ["skills"], "downloads": ["download"], "seoAudit": ["seo"],
        "codeStats": ["code-stats"], "clipboard": ["clipboard"], "attention": ["attention"],
        "notchShelf": ["shelf", "browser"], "colorPicker": ["color"],
        "emoji": ["emoji"], "presenter": ["presenter"], "lidAwake": ["lid-awake"],
        "system": ["system", "apps", "tools"], "systemStats": ["stats"],
        "homebrew": ["brew"], "cleaner": ["cleaner"], "appMaintenance": ["maintenance"],
        "jev": ["jev"], "virtualCamera": ["camera"], "audioMixer": ["audio"],
    ]
}

public struct HostCLIProviderState: Codable, Equatable, Sendable {
    public let id: String
    public let installed: Bool
    public let compatible: Bool
    public let enabled: Bool
    public let running: Bool
    public let version: String?
    public let disablePending: Bool
    public let removalPending: Bool
    public let processIdentifier: Int32?

    public var available: Bool {
        installed && compatible && enabled && running && version != nil
            && !disablePending && !removalPending
    }
}

public struct HostCLIProviderRegistry: Sendable {
    public typealias Invoke = @Sendable (HostCLIRequest) async throws -> Data
    public struct Provider: Sendable {
        public let state: HostCLIProviderState
        public let catalog: HostCLIProviderCatalog
    }
    public let providers: [Provider]
    public let issues: [String: String]

    public static func load(invoke: Invoke) async throws -> Self {
        let states = try await states(invoke: invoke)
        var providers: [Provider] = []
        var issues: [String: String] = [:]
        for state in states
        where state.available && HostCLIProviderCatalog.prefixes[state.id] != nil {
            try Task.checkCancellation()
            do {
                let data = try await invoke(
                    HostCLIRequest(
                        action: .invoke, id: state.id, operation: state.id + ".cli.catalog",
                        timeout: 2))
                let catalog = try HostCLIProviderCatalog.decode(data, owner: state.id)
                providers.append(Provider(state: state, catalog: catalog))
            } catch is CancellationError { throw CancellationError() } catch {
                issues[state.id] = error.localizedDescription
            }
        }
        let current = try await Self.states(invoke: invoke)
        providers.removeAll { provider in
            guard current.contains(provider.state) else {
                issues[provider.state.id] = "The provider changed during discovery."
                return true
            }
            return false
        }
        return Self(providers: providers, issues: issues)
    }

    public static func states(invoke: Invoke) async throws -> [HostCLIProviderState] {
        let data = try await invoke(HostCLIRequest(action: .ls))
        guard data.count <= HostCLIRequest.maximumPayload else {
            throw HostCLIError.rejected("Invalid provider list.")
        }
        let states = try JSONDecoder().decode([HostCLIProviderState].self, from: data)
        guard states.count <= 39, Set(states.map(\.id)).count == states.count else {
            throw HostCLIError.rejected("Invalid provider list.")
        }
        return states
    }

    public func execute(
        _ arguments: [String], input: Data = Data(),
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        streamWrite: (@Sendable (Data, Bool) async throws -> Void)? = nil, invoke: @escaping Invoke
    ) async throws -> ExtensionCLIReply {
        guard let prefix = arguments.first,
            let provider = providers.first(where: {
                $0.catalog.commands.contains { $0.route.first == prefix }
                    || ($0.catalog.machineAliases ?? []).contains(prefix)
            }),
            let command = provider.catalog.commands.filter({ arguments.starts(with: $0.route) })
                .max(by: { $0.route.count < $1.route.count })
                ?? provider.catalog.commands.first(where: {
                    $0.route.first == prefix
                        || provider.catalog.owner == "machines"
                            && (provider.catalog.machineAliases ?? []).contains(prefix)
                })
        else { throw HostCLIError.rejected("No enabled extension provides this command.") }
        guard try await Self.states(invoke: invoke).contains(provider.state) else {
            throw HostCLIError.rejected("The command provider was disabled or changed.")
        }
        let isAlias = (provider.catalog.machineAliases ?? []).contains(prefix)
        let routedArguments = isAlias ? arguments : Array(arguments.dropFirst())
        let executionOperation =
            isAlias ? (provider.catalog.aliasOperation ?? command.operation) : command.operation
        if let operation = command.streamOperation {
            let context = try HostCLIInvocationContext(
                arguments: routedArguments, standardInput: input,
                workingDirectory: workingDirectory)
            let stream = try await HostCLIStream.start(
                owner: provider.state.id, operation: operation, request: context,
                maximumDuration: command.streamDeadline ?? 1800, invoke: invoke)
            if let streamWrite {
                let code = try await stream.consume(write: streamWrite)
                return try ExtensionCLIReply(stdout: "", stderr: "", exitCode: code)
            }
            let capture = HostCLIStreamCapture()
            let code = try await stream.consume(write: { try await capture.append($0, stderr: $1) })
            return try await capture.reply(code: code)
        }
        let request = try Self.request(
            arguments: routedArguments, input: input, catalog: provider.catalog,
            workingDirectory: workingDirectory)
        let data = try await invoke(
            HostCLIRequest(
                action: .invoke, id: provider.state.id, operation: executionOperation,
                payload: request, timeout: command.timeout))
        try Task.checkCancellation()
        guard try await Self.states(invoke: invoke).contains(provider.state) else {
            throw HostCLIError.rejected("The command provider changed before its result arrived.")
        }
        let reply = try JSONDecoder().decode(ExtensionCLIReply.self, from: data)
        try reply.validate()
        return reply
    }

    public static func request(
        arguments: [String], input: Data, catalog: HostCLIProviderCatalog,
        workingDirectory: String = FileManager.default.currentDirectoryPath
    ) throws -> Data {
        guard input.isEmpty || catalog.acceptsInput == true else {
            throw HostCLIError.usage("This provider does not accept stdin.")
        }
        return try JSONEncoder().encode(
            HostCLIInvocationContext(
                arguments: arguments, standardInput: input, workingDirectory: workingDirectory))
    }
}

public struct HostCLINativeTool: Codable, Sendable {
    public let name: String
    public let title: String
    public let summary: String
    public let operation: String
    public let inputSchema: HostCLIJSON
    public init(
        name: String, title: String, summary: String, operation: String, inputSchema: HostCLIJSON
    ) {
        self.name = name; self.title = title; self.summary = summary; self.operation = operation;
        self.inputSchema = inputSchema
    }
    public func validate(owner: String) throws {
        guard name.utf8.count <= 128,
            name.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || $0 == 95
            }),
            !title.isEmpty, title.utf8.count <= 256, summary.utf8.count <= 4096,
            (owner == "database" && name.hasPrefix("database_"))
                || (owner == "jev" && name == "edith_find"),
            inputSchema.object?["type"] == .string("object"),
            try inputSchema.encoded().count <= 65536
        else { throw HostCLIError.rejected("Invalid native tool declaration.") }
        _ = try HostCLIRequest(action: .invoke, id: owner, operation: operation)
    }
    public var tool: HostCLIJSON {
        .object([
            "name": .string(name), "title": .string(title), "description": .string(summary),
            "inputSchema": inputSchema,
        ])
    }
}

private actor HostCLIStreamCapture {
    private var stdout = Data()
    private var stderr = Data()
    func append(_ data: Data, stderr error: Bool) throws {
        guard stdout.count + stderr.count + data.count <= ExtensionCLIReply.maximumOutputBytes
        else { throw HostCLIError.rejected("The command output exceeds 4 MiB.") }
        if error { stderr.append(data) } else { stdout.append(data) }
    }
    func reply(code: Int32) throws -> ExtensionCLIReply {
        guard let stdout = String(data: stdout, encoding: .utf8),
            let stderr = String(data: stderr, encoding: .utf8)
        else {
            throw HostCLIError.rejected(
                "The command returned non-text output; use direct CLI streaming.")
        }
        return try ExtensionCLIReply(stdout: stdout, stderr: stderr, exitCode: code)
    }
}
