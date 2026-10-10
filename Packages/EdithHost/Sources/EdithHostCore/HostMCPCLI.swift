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
    private let invoke: HostCLIProviderRegistry.Invoke
    private let send: Send
    private let stop: @Sendable () -> Void
    private let coreExecute: (@Sendable ([String]) async throws -> ExtensionCLIReply)?
    private var initialized = false
    private var ready = false
    private var stopping = false
    private var jobs: [String: Job] = [:]
    private var retired: [UUID: Task<Void, Never>] = [:]
    private var failure: String?

    public init(
        version: String, invoke: @escaping HostCLIProviderRegistry.Invoke, send: @escaping Send,
        stop: @escaping @Sendable () -> Void = {},
        coreExecute: (@Sendable ([String]) async throws -> ExtensionCLIReply)? = nil
    ) {
        self.version = version; self.invoke = invoke; self.send = send
        self.stop = stop; self.coreExecute = coreExecute
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
                    "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                    "instructions": .string(
                        "Tools run original commands from compatible enabled downloaded extensions. Destructive commands preview unless confirm is true."
                    ),
                ]))
            return
        }
        if method == "ping" { try await result(id: id, value: .object([:])); return }
        guard ready else {
            try await error(id: id, code: -32002, message: "Initialize MCP first"); return
        }
        guard ["tools/list", "tools/call"].contains(method) else {
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

    private func execute(_ method: String, params: [String: HostCLIJSON]) async throws
        -> HostCLIJSON
    {
        let registry = try await HostCLIProviderRegistry.load(invoke: invoke)
        let coreCatalog: HostCLIProviderCatalog?
        do {
            coreCatalog = try HostCLIProviderCatalog.decode(
                await invoke(
                    HostCLIRequest(
                        action: .invoke, id: "host", operation: "host.cli.catalog", timeout: 2)),
                owner: "host")
        } catch is CancellationError { throw CancellationError() } catch { coreCatalog = nil }
        if method == "tools/list" {
            guard Set(params.keys).isSubset(of: ["_meta"]) else {
                throw HostCLIError.usage("Tool pagination is not supported.")
            }
            let commands =
                registry.providers.flatMap { $0.catalog.commands } + (coreCatalog?.commands ?? [])
            let native = registry.providers.flatMap { $0.catalog.nativeTools ?? [] }.map(\.tool)
            return .object([
                "tools": .array(
                    (commands.map(Self.tool) + native).sorted {
                        ($0.object?["name"]?.string ?? "") < ($1.object?["name"]?.string ?? "")
                    })
            ])
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
            let data = try await invoke(
                HostCLIRequest(
                    action: .invoke, id: provider.state.id, operation: tool.operation,
                    payload: (params["arguments"] ?? .object([:])).encoded()))
            try Task.checkCancellation()
            guard data.count <= HostMCPStdio.maximumMessageBytes,
                try await HostCLIProviderRegistry.states(invoke: invoke).contains(provider.state),
                let result = try JSONDecoder().decode(HostCLIJSON.self, from: data).object,
                let content = result["content"]?.array, content.count <= 256,
                content.allSatisfy({
                    ["text", "image", "audio", "resource", "resource_link"].contains(
                        $0.object?["type"]?.string ?? "")
                }),
                result["isError"] == nil || result["isError"]?.bool != nil
            else { throw HostCLIError.rejected("Invalid or stale native tool result.") }
            return .object(result)
        }
        guard Set(params.keys).isSubset(of: ["name", "arguments", "_meta"]),
            let name = params["name"]?.string,
            let command =
                (registry.providers.flatMap({ $0.catalog.commands }) + (coreCatalog?.commands ?? []))
                .first(where: {
                    $0.toolName == name
                }),
            params["arguments"] == nil || params["arguments"]?.object != nil
        else { throw HostCLIError.usage("Unknown or unavailable tool.") }
        let object = params["arguments"]?.object ?? [:]
        guard Set(object.keys).isSubset(of: ["arguments", "confirm"]),
            object["arguments"] == nil || object["arguments"]?.array != nil,
            object["confirm"] == nil || object["confirm"]?.bool != nil
        else { throw HostCLIError.usage("Invalid tool arguments.") }
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
        var routed = command.route + ["--json"]
        if command.destructive, object["confirm"] == .bool(true) { routed.append("--yes") }
        routed += arguments
        do {
            let reply: ExtensionCLIReply
            if coreCatalog?.commands.contains(command) == true {
                if let coreExecute {
                    reply = try await coreExecute(routed)
                } else {
                    reply = try JSONDecoder().decode(
                        ExtensionCLIReply.self,
                        from: await invoke(HostCoreCLIEnvelope(arguments: routed).request()))
                }
                try reply.validate()
            } else {
                reply = try await registry.execute(routed, invoke: invoke)
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

    private static func tool(_ command: HostCLIProviderCommand) -> HostCLIJSON {
        var properties: [String: HostCLIJSON] = [
            "arguments": .object([
                "type": .string("array"), "items": .object(["type": .string("string")]),
                "maxItems": .integer(128),
            ])
        ]
        if command.destructive {
            properties["confirm"] = .object([
                "type": .string("boolean"),
                "description": .string("Leave false to preview. Pass true to apply."),
            ])
        }
        return .object([
            "name": .string(command.toolName),
            "title": .string("ed " + command.route.joined(separator: " ")),
            "description": .string(
                command.summary
                    + (command.destructive ? " Previews by default; pass confirm to apply." : "")),
            "inputSchema": .object([
                "type": .string("object"), "properties": .object(properties),
                "additionalProperties": .bool(false),
            ]),
        ])
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
