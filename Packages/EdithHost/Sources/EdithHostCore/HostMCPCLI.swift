import EdithExtensionSupport
import Foundation

public actor HostMCPCLI {
    public typealias Send = @Sendable (Data) async throws -> Void
    public typealias Receive = @Sendable () async throws -> Data?
    private struct Job {
        let token: UUID
        let task: Task<Void, Never>
    }
    private let version: String
    let invoke: HostCLIProviderRegistry.Invoke
    private let send: Send
    private let stop: @Sendable () -> Void
    private let coreExecute: (@Sendable ([String], Data) async throws -> ExtensionCLIReply)?
    let index: @Sendable () -> [HostExtension]
    private var servedTools: [String]?
    private var initialized = false
    private var ready = false
    private var stopping = false
    private var jobs: [String: Job] = [:]
    private var retired: [UUID: Task<Void, Never>] = [:]
    private var failure: String?

    public init(
        version: String, invoke: @escaping HostCLIProviderRegistry.Invoke, send: @escaping Send,
        stop: @escaping @Sendable () -> Void = {},
        coreExecute: (@Sendable ([String], Data) async throws -> ExtensionCLIReply)? = nil,
        index: @escaping @Sendable () -> [HostExtension] = { (try? HostIndex.bundled()) ?? [] }
    ) {
        self.version = version; self.invoke = invoke; self.send = send
        self.stop = stop; self.coreExecute = coreExecute; self.index = index
    }

    public func run(receive: Receive) async throws {
        do {
            while !stopping, let data = try await receive() {
                try Task.checkCancellation()
                try await accept(data)
                if let failure { throw HostCLIError.rejected(failure) }
            }
        } catch { await shutdown(); throw error }
        await shutdown()
    }

    public func accept(_ data: Data) async throws {
        guard !stopping else { throw HostCLIError.rejected("MCP is stopping.") }
        guard data.count <= HostMCPStdio.maximumMessageBytes,
            let value = try? JSONDecoder().decode(HostCLIJSON.self, from: data)
        else { try await error(id: .null, code: -32700, message: "Parse error"); return }
        guard let object = value.object, object["jsonrpc"] == .string("2.0"),
            let method = object["method"]?.string,
            object["params"] == nil || object["params"]?.object != nil,
            object["result"] == nil, object["error"] == nil
        else { try await error(id: .null, code: -32600, message: "Invalid request"); return }
        let params = object["params"]?.object ?? [:]
        guard let id = object["id"] else {
            if method == "notifications/initialized", initialized {
                ready = true
            } else if method == "notifications/cancelled", let id = params["requestId"],
                let key = Self.key(id)
            {
                cancel(key)
            }
            return
        }
        guard let key = Self.key(id) else {
            try await error(id: .null, code: -32600, message: "Invalid request identifier"); return
        }
        if method == "initialize" {
            guard !initialized, let protocolVersion = params["protocolVersion"]?.string,
                params["capabilities"]?.object != nil, params["clientInfo"]?.object != nil
            else {
                try await error(id: id, code: -32602, message: "Invalid initialization"); return
            }
            initialized = true
            let supported = ["2025-11-25"]
            try await result(
                id: id,
                value: .object([
                    "protocolVersion": .string(
                        supported.contains(protocolVersion) ? protocolVersion : supported[0]),
                    "serverInfo": .object([
                        "name": .string("edith"), "version": .string(version),
                        "title": .string("Edith"),
                    ]),
                    "capabilities": .object([
                        "tools": .object(["listChanged": .bool(true)]),
                        "resources": .object([
                            "listChanged": .bool(false), "subscribe": .bool(false),
                        ]),
                    ]),
                    "instructions": .string(Self.instructions),
                ]))
            return
        }
        if method == "ping" { try await result(id: id, value: .object([:])); return }
        guard ready else {
            try await error(id: id, code: -32002, message: "Initialize MCP first"); return
        }
        guard ["tools/list", "tools/call", "resources/list", "resources/read"].contains(method)
        else {
            try await error(id: id, code: -32601, message: "Method not found"); return
        }
        guard jobs[key] == nil, jobs.count + retired.count < 8 else {
            try await error(
                id: id, code: -32000, message: "Duplicate identifier or too many active requests");
            return
        }
        let token = UUID()
        let task = Task {
            do {
                let value = try await self.execute(method, params: params)
                try Task.checkCancellation()
                if method == "tools/call", Self.changesTools(params["name"]?.string) {
                    await self.announceToolChanges()
                }
                await self.finish(key, token: token, id: id, value: value, message: nil)
            } catch is CancellationError {
                await self.finish(key, token: token, id: id, value: nil, message: nil)
            } catch {
                await self.finish(
                    key, token: token, id: id, value: nil, message: error.localizedDescription)
            }
        }
        jobs[key] = Job(token: token, task: task)
    }

    public func shutdown() async {
        stopping = true
        let pending = Array(jobs.values.map(\.task)) + Array(retired.values)
        jobs.removeAll()
        for task in pending { task.cancel() }
        for task in pending { await task.value }
        retired.removeAll()
    }

    private static let findOperation = "jev.find"

    private static func findArguments(_ arguments: HostCLIJSON, commands: [HostCLIProviderCommand])
        -> HostCLIJSON
    {
        var object = arguments.object ?? [:]
        object["tools"] = .array(
            commands.map {
                .object([
                    "tool": .string($0.toolName), "summary": .string($0.summary),
                    "area": .string($0.route.first ?? $0.toolName),
                ])
            })
        return .object(object)
    }

    private func jevIsConfigured(_ registry: HostCLIProviderRegistry) async -> Bool {
        guard
            registry.providers.contains(where: {
                ($0.catalog.nativeTools ?? []).contains { $0.operation == Self.findOperation }
            }),
            let request = try? HostCLIRequest(
                action: .invoke, id: "jev", operation: "jev.status",
                payload: Data("{\"probe\":false}".utf8), timeout: 2),
            let data = try? await invoke(request),
            let state = (try? JSONDecoder().decode(HostCLIJSON.self, from: data))?.object?["state"]?
                .string
        else { return false }
        return state != "notConfigured" && state != "keyUnreadable"
    }

    private static func publicCommand(_ command: HostCLIProviderCommand) -> Bool {
        command.route != ["agent", "activity", "hook"]
    }

    private func loadCatalogs() async throws -> (HostCLIProviderRegistry, HostCLIProviderCatalog?) {
        let registry = try await HostCLIProviderRegistry.load(invoke: invoke)
        let coreCatalog: HostCLIProviderCatalog?
        do {
            coreCatalog = try HostCLIProviderCatalog.decode(
                await invoke(
                    HostCLIRequest(
                        action: .invoke, id: "host", operation: "host.cli.catalog", timeout: 2)),
                owner: "host")
        } catch is CancellationError { throw CancellationError() } catch { coreCatalog = nil }
        return (registry, coreCatalog)
    }

    private func publicTools(_ registry: HostCLIProviderRegistry, _ core: HostCLIProviderCatalog?)
        async -> [HostCLIJSON]
    {
        let commands =
            registry.providers.flatMap { $0.catalog.allCommands }.filter(Self.publicCommand)
            + (core?.commands ?? [])
        let jevConfigured = await jevIsConfigured(registry)
        let native = registry.providers.flatMap { provider in
            (provider.catalog.nativeTools ?? []).filter {
                $0.operation != Self.findOperation || jevConfigured
            }
        }.map(\.tool)
        return (commands.map(Self.tool) + native + [HostMCPResources.catalogTool]).sorted {
            ($0.object?["name"]?.string ?? "") < ($1.object?["name"]?.string ?? "")
        }
    }

    private static func names(_ tools: [HostCLIJSON]) -> [String] {
        tools.compactMap { $0.object?["name"]?.string }
    }

    private static let lifecycleTools: Set<String> = [
        "install", "update", "enable", "disable", "remove", "setup", "sideload",
    ].reduce(into: []) { $0.insert("edith_extensions_" + $1) }

    private static func changesTools(_ name: String?) -> Bool {
        name.map(lifecycleTools.contains) ?? false
    }

    private func announceToolChanges() async {
        guard let served = servedTools, !stopping, let (registry, core) = try? await loadCatalogs()
        else { return }
        let current = Self.names(await publicTools(registry, core))
        guard current != served, !stopping else { return }
        servedTools = current
        try? await send(
            HostCLIJSON.object([
                "jsonrpc": .string("2.0"), "method": .string("notifications/tools/list_changed"),
            ]).encoded())
    }

    private func execute(_ method: String, params: [String: HostCLIJSON]) async throws
        -> HostCLIJSON
    {
        if method == "resources/list" {
            guard Set(params.keys).isSubset(of: ["_meta"]) else {
                throw HostCLIError.usage("Resource pagination is not supported.")
            }
            return HostMCPResources.list(index())
        }
        if method == "resources/read" {
            guard Set(params.keys).isSubset(of: ["uri", "_meta"]), let uri = params["uri"]?.string,
                let resource = HostMCPResources.read(uri, index: index())
            else { throw HostCLIError.usage("Unknown resource. Call resources/list.") }
            return resource
        }
        let (registry, coreCatalog) = try await loadCatalogs()
        if method == "tools/list" {
            guard Set(params.keys).isSubset(of: ["_meta"]) else {
                throw HostCLIError.usage("Tool pagination is not supported.")
            }
            let tools = await publicTools(registry, coreCatalog)
            servedTools = Self.names(tools)
            return .object(["tools": .array(tools)])
        }
        if params["name"]?.string == HostMCPResources.catalogToolName {
            guard Set(params.keys).isSubset(of: ["name", "arguments", "_meta"]),
                params["arguments"] == nil || params["arguments"]?.object != nil
            else { throw HostCLIError.usage("Invalid catalog arguments.") }
            return try await catalog(params["arguments"]?.object ?? [:])
        }
        if let name = params["name"]?.string,
            let provider = registry.providers.first(where: {
                ($0.catalog.nativeTools ?? []).contains { $0.name == name }
            }),
            let tool = provider.catalog.nativeTools?.first(where: { $0.name == name })
        {
            guard Set(params.keys).isSubset(of: ["name", "arguments", "_meta"]),
                params["arguments"] == nil || params["arguments"]?.object != nil
            else { throw HostCLIError.usage("Invalid native tool arguments.") }
            guard try await HostCLIProviderRegistry.states(invoke: invoke).contains(provider.state)
            else { throw HostCLIError.rejected("The native tool provider changed.") }
            var arguments = params["arguments"] ?? .object([:])
            if tool.operation == Self.findOperation {
                let commands =
                    registry.providers.flatMap { $0.catalog.allCommands }.filter(Self.publicCommand)
                    + (coreCatalog?.commands ?? [])
                arguments = Self.findArguments(arguments, commands: commands)
            }
            let data = try await invoke(
                HostCLIRequest(
                    action: .invoke, id: provider.state.id, operation: tool.operation,
                    payload: arguments.encoded()))
            try Task.checkCancellation()
            guard data.count <= 8 * 1024 * 1024,
                try await HostCLIProviderRegistry.states(invoke: invoke).contains(provider.state),
                let result = try JSONDecoder().decode(HostCLIJSON.self, from: data).object,
                let content = result["content"]?.array, content.count <= 256,
                content.allSatisfy(Self.validContent),
                result["isError"] == nil || result["isError"]?.bool != nil
            else { throw HostCLIError.rejected("Invalid or stale native tool result.") }
            return .object(result)
        }
        guard Set(params.keys).isSubset(of: ["name", "arguments", "_meta"]),
            let name = params["name"]?.string,
            let command =
                (registry.providers.flatMap({ $0.catalog.allCommands }).filter(Self.publicCommand)
                + (coreCatalog?.commands ?? []))
                .first(where: {
                    $0.toolName == name
                }),
            params["arguments"] == nil || params["arguments"]?.object != nil
        else { throw HostCLIError.usage("Unknown or unavailable tool.") }
        let object = params["arguments"]?.object ?? [:]
        guard Set(object.keys).isSubset(of: ["arguments", "confirm", "input"]),
            object["arguments"] == nil || object["arguments"]?.array != nil,
            object["confirm"] == nil || object["confirm"]?.bool != nil,
            object["input"] == nil || object["input"]?.string != nil
        else { throw HostCLIError.usage("Invalid tool arguments.") }
        let input = Data((object["input"]?.string ?? "").utf8)
        guard input.count <= HostCLIInvocationContext.maximumInputBytes,
            object["input"] == nil || command.readsInput == true
        else { throw HostCLIError.usage("This tool does not accept the supplied stdin.") }
        let values = object["arguments"]?.array ?? []
        guard values.allSatisfy({ $0.string != nil }) else {
            throw HostCLIError.usage("Tool arguments must all be strings.")
        }
        let arguments = values.compactMap(\.string)
        guard !arguments.contains(where: { $0 == "--yes" || $0.hasPrefix("--yes=") || $0 == "-y" })
        else {
            throw HostCLIError.usage(
                "Pass confirm: true instead of a confirmation flag inside arguments.")
        }
        if Self.needsConfirmation(command), object["confirm"] != .bool(true) {
            let preview = try HostCLIJSON.object([
                "preview": .bool(true), "requiresConfirmation": .bool(true),
                "command": .strings(command.route + arguments),
            ]).encoded()
            return .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(String(decoding: preview, as: UTF8.self)),
                    ])
                ]), "isError": .bool(false),
            ])
        }
        var routed = command.route
        if command.jsonOutput != false, !arguments.contains("--json") { routed.append("--json") }
        if command.destructive, object["confirm"] == .bool(true), command.route.first != "agent",
            command.route != ["extensions", "setup"]
        {
            routed.append("--yes")
        }
        routed += arguments
        do {
            let reply: ExtensionCLIReply
            if let coreExecute {
                reply = try await coreExecute(routed, input)
                try reply.validate()
            } else if coreCatalog?.commands.contains(command) == true {
                reply = try JSONDecoder().decode(
                    ExtensionCLIReply.self,
                    from: await invoke(
                        HostCoreCLIEnvelope(arguments: routed, input: input).request(
                            timeout: command.timeout)))
                try reply.validate()
            } else {
                reply = try await registry.execute(routed, input: input, invoke: invoke)
            }
            let output =
                reply.exitCode == 0
                ? reply.stdout : reply.stderr.isEmpty ? reply.stdout : reply.stderr
            return .object([
                "content": .array([.object(["type": .string("text"), "text": .string(output)])]),
                "isError": .bool(reply.exitCode != 0),
            ])
        } catch is CancellationError { throw CancellationError() } catch {
            return .object([
                "content": .array([
                    .object(["type": .string("text"), "text": .string(error.localizedDescription)])
                ]), "isError": .bool(true),
            ])
        }
    }

    private static let confirmedRoutes: Set<[String]> = [
        ["extensions", "install"], ["extensions", "update"], ["extensions", "enable"],
        ["extensions", "disable"], ["extensions", "remove"],
    ]

    private static func previewsOnly(_ command: HostCLIProviderCommand) -> Bool {
        command.destructive
            && (command.route.first == "agent" || command.route == ["extensions", "setup"])
    }

    private static func needsConfirmation(_ command: HostCLIProviderCommand) -> Bool {
        previewsOnly(command) || confirmedRoutes.contains(command.route)
    }

    private static func summary(_ command: HostCLIProviderCommand) -> String {
        switch command.route {
        case ["extensions", "install"]:
            return
                "Install and start one extension. arguments: [id] from edith_catalog. Changes this Mac, so ask the user first."
        case ["extensions", "ls"]:
            return
                "List extensions and their install state. edith_catalog adds guides and examples."
        case ["app", "navigate"]:
            return
                "Show a page in the Edith app. arguments: [route]; an extension's route is its id."
        default: return command.summary
        }
    }

    private static func tool(_ command: HostCLIProviderCommand) -> HostCLIJSON {
        var properties: [String: HostCLIJSON] = [
            "arguments": .object([
                "type": .string("array"), "items": .object(["type": .string("string")]),
                "maxItems": .integer(128),
            ])
        ]
        if command.destructive || needsConfirmation(command) {
            properties["confirm"] = .object([
                "type": .string("boolean"),
                "description": .string("Leave false to preview. Pass true to apply."),
            ])
        }
        if command.readsInput == true {
            properties["input"] = .object([
                "type": .string("string"),
                "maxLength": .integer(Int64(HostCLIInvocationContext.maximumInputBytes)),
                "description": .string("Text supplied as the original command's stdin."),
            ])
        }
        return .object([
            "name": .string(command.toolName),
            "title": .string("ed " + command.route.joined(separator: " ")),
            "description": .string(
                summary(command)
                    + (command.destructive || needsConfirmation(command)
                        ? " Previews by default; pass confirm to apply." : "")),
            "inputSchema": .object([
                "type": .string("object"), "properties": .object(properties),
                "additionalProperties": .bool(false),
            ]),
        ])
    }
    private static func validContent(_ value: HostCLIJSON) -> Bool {
        guard let object = value.object, let type = object["type"]?.string else { return false }
        switch type {
        case "text": return object["text"]?.string != nil
        case "image", "audio":
            return object["mimeType"]?.string?.isEmpty == false
                && object["data"]?.string.flatMap { Data(base64Encoded: $0) } != nil
        case "resource": return object["resource"]?.object?["uri"]?.string != nil
        case "resource_link":
            return object["uri"]?.string != nil && object["name"]?.string != nil
        default: return false
        }
    }
    private static func key(_ id: HostCLIJSON) -> String? {
        switch id {
        case .string(let value): value.utf8.count <= 256 ? "s:" + value : nil
        case .integer(let value): "i:" + String(value)
        default: nil
        }
    }
    private func cancel(_ key: String) {
        guard let job = jobs.removeValue(forKey: key) else { return }
        retired[job.token] = job.task
        job.task.cancel()
    }
    private func finish(
        _ key: String, token: UUID, id: HostCLIJSON, value: HostCLIJSON?, message: String?
    ) async {
        retired.removeValue(forKey: token)
        guard !stopping, let job = jobs[key], job.token == token else { return }
        jobs.removeValue(forKey: key)
        do {
            if let value {
                try await result(id: id, value: value)
            } else if let message {
                try await error(id: id, code: -32602, message: message)
            }
        } catch { failure = error.localizedDescription; stopping = true; stop() }
    }
    private func result(id: HostCLIJSON, value: HostCLIJSON) async throws {
        try await send(
            HostCLIJSON.object(["jsonrpc": .string("2.0"), "id": id, "result": value]).encoded())
    }
    private func error(id: HostCLIJSON, code: Int64, message: String) async throws {
        try await send(
            HostCLIJSON.object([
                "jsonrpc": .string("2.0"), "id": id,
                "error": .object(["code": .integer(code), "message": .string(message)]),
            ]).encoded())
    }
}
