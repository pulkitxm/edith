import Darwin
import EdithExtensionSupport
import Foundation

public struct HostCommandCLI: Sendable {
    public let version: String
    public let tooling: HostToolingCLI
    private let invoke: HostCLIProviderRegistry.Invoke

    public init(
        version: String, tooling: HostToolingCLI, invoke: @escaping HostCLIProviderRegistry.Invoke
    ) {
        self.version = version; self.tooling = tooling; self.invoke = invoke
    }

    public static func main(arguments: [String]) -> Never {
        let work = Task {
            do {
                guard let identifier = Bundle.main.bundleIdentifier else {
                    throw HostCLIError.unavailable
                }
                let support = try FileManager.default.url(
                    for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                    create: false)
                let identity = try HostIdentity(identifier: identifier, supportDirectory: support)
                let executable =
                    HostToolingCLI.bundledLauncher()
                    ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
                let tooling: HostToolingCLI
                #if EDITH_CLI_FIXTURE
                if identifier.hasPrefix("com.pulkit.edith.tests.cli-"),
                    let fixtureHome = ProcessInfo.processInfo.environment["EDITH_CLI_FIXTURE_HOME"],
                    fixtureHome.hasPrefix("/")
                {
                    let home = URL(fileURLWithPath: fixtureHome, isDirectory: true)
                    tooling = HostToolingCLI(
                        home: home, executable: executable,
                        directory: home.appendingPathComponent("bin"),
                        path: [home.appendingPathComponent("bin").path])
                } else {
                    tooling = HostToolingCLI(
                        home: FileManager.default.homeDirectoryForCurrentUser,
                        executable: executable,
                        path: (ProcessInfo.processInfo.environment["PATH"] ?? "").split(
                            separator: ":"
                        ).map(String.init))
                }
                #else
                tooling = HostToolingCLI(
                    home: FileManager.default.homeDirectoryForCurrentUser,
                    executable: executable,
                    path: (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
                        .map(String.init))
                #endif
                let cli = HostCommandCLI(
                    version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                        as? String ?? "development",
                    tooling: tooling,
                    invoke: { try await HostCommandCLITransport.invoke($0, identity: identity) })
                if arguments == ["mcp"] {
                    let io = try HostMCPStdio()
                    let server = HostMCPCLI(
                        version: cli.version, invoke: cli.invoke, send: { try await io.send($0) },
                        stop: { io.cancel() }, coreExecute: { try await cli.execute($0, input: $1) }
                    )
                    do {
                        try await withTaskCancellationHandler {
                            try await server.run(receive: { try await io.receive() })
                        } onCancel: {
                            io.cancel()
                        }
                    } catch { io.cancel(); throw error }
                    exit(0)
                }
                let input = try await inputForCommand(arguments, invoke: cli.invoke)
                let stdout = try HostCLIByteOutput(descriptor: STDOUT_FILENO)
                let stderr = try HostCLIByteOutput(descriptor: STDERR_FILENO)
                let reply = await cli.run(
                    arguments, input: input,
                    streamWrite: { data, error in
                        try await (error ? stderr : stdout).send(data)
                    })
                try await stdout.send(Data(reply.stdout.utf8))
                try await stderr.send(Data(reply.stderr.utf8))
                exit(reply.exitCode)
            } catch {
                if let output = try? HostCLIByteOutput(descriptor: STDERR_FILENO) {
                    try? await output.send(
                        Data("error: \(String(error.localizedDescription.prefix(4096)))\n".utf8))
                }
                exit(
                    (error as? HostCLIError).map { $0.exitCode == 3 ? 4 : $0.exitCode }
                        ?? (error is CancellationError ? 130 : 1))
            }
        }
        let signals = HostCLISignalCancellation(task: work)
        withExtendedLifetime(signals) { dispatchMain() }
    }

    public func run(
        _ arguments: [String], input: Data = Data(),
        streamWrite: (@Sendable (Data, Bool) async throws -> Void)? = nil
    ) async -> ExtensionCLIReply {
        do {
            let reply = try await execute(arguments, input: input, streamWrite: streamWrite);
            try Task.checkCancellation(); return reply
        } catch {
            let failure = error as? HostCLIError
            var code = failure?.exitCode ?? (error is CancellationError ? 130 : 1)
            if case .unavailable = failure { code = 4 }
            return try! ExtensionCLIReply(
                stdout: "", stderr: "error: \(String(error.localizedDescription.prefix(4096)))\n",
                exitCode: code)
        }
    }

    public func execute(
        _ arguments: [String], input: Data = Data(),
        streamWrite: (@Sendable (Data, Bool) async throws -> Void)? = nil
    ) async throws
        -> ExtensionCLIReply
    {
        _ = try ExtensionCLIRequest(arguments: arguments)
        guard input.count <= HostCLIInvocationContext.maximumInputBytes else {
            throw HostCLIError.usage("Input exceeds 4 MiB.")
        }
        try Task.checkCancellation()
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["help"] {
            return try HostCLIOutput.text(Self.help)
        }
        let command = arguments[0]
        if Self.coreCommands.contains(command), arguments.last == "--help" {
            return try HostCLIOutput.text(HostCLIHelp.text(Array(arguments.dropLast())))
        }
        if ["version", "--version"].contains(command) {
            let args = try HostCLIArguments(Array(arguments.dropFirst()), flags: ["--json"])
            try args.require(words: 0...0, flags: ["--json"])
            if args.flags.contains("--json") {
                return try HostCLIOutput.json(
                    .object([
                        "version": .string(version),
                        "appRunning": .bool(
                            (try? await invoke(HostCLIRequest(action: .ls))) != nil),
                    ]))
            }
            return try HostCLIOutput.text(version)
        }
        if command == "guide" {
            let args = try HostCLIArguments(Array(arguments.dropFirst()), flags: ["--json"])
            try args.require(words: 0...1, flags: ["--json"])
            if args.flags.contains("--json") {
                guard args.words.isEmpty else {
                    throw HostCLIError.usage("--json does not take a guide topic.")
                }
                let registry = try? await HostCLIProviderRegistry.load(invoke: invoke)
                return try HostCLIOutput.json(
                    HostCLIHelp.document(version: version, registry: registry))
            }
            guard args.words.isEmpty || args.words == ["agent"] else {
                throw HostCLIError.usage("Unknown guide topic.")
            }
            return try HostCLIOutput.text(
                args.words.isEmpty ? HostGuideCLI.text : HostGuideCLI.agentSnippet)
        }
        if command == "schema" {
            guard arguments.count == 1 else {
                throw HostCLIError.usage("ed schema takes no arguments.")
            }
            let registry = try? await HostCLIProviderRegistry.load(invoke: invoke)
            let settings = try Self.ownedSettings(registry)
            return try HostCLIOutput.json(
                .object([
                    "$schema": .string("https://json-schema.org/draft/2020-12/schema"),
                    "$id": .string("https://edith.pulkit.page/schema/config.json"),
                    "title": .string("Edith configuration"),
                    "type": .string("object"), "additionalProperties": .bool(false),
                    "properties": .object(
                        Dictionary(
                            uniqueKeysWithValues: settings.filter { !$0.readOnly }.map {
                                ($0.key, $0.schema)
                            })),
                ]))
        }
        if ["install", "uninstall", "status", "completions"].contains(command) {
            return try tooling.execute(arguments)
        }
        if command == "__complete" { return try await complete(Array(arguments.dropFirst())) }
        if command == "config" {
            var configArguments = Array(arguments.dropFirst())
            var configInput = input
            if configArguments.first == "import" {
                let parsed = try HostCLIArguments(
                    Array(configArguments.dropFirst()), flags: ["--json", "--dry-run"])
                try parsed.require(words: 1...1, flags: ["--json", "--dry-run"])
                if configInput.isEmpty, parsed.words[0] != "-" {
                    configInput = try await Self.inputForCommand(arguments, invoke: invoke)
                }
                configArguments = ["import", "-"] + parsed.flags.sorted()
            }
            return try await configuration(configArguments, input: configInput)
        }
        if ["app", "permissions"].contains(command) {
            if arguments.starts(with: ["app", "relaunch"]) {
                let args = try HostCLIArguments(
                    Array(arguments.dropFirst(2)), flags: ["--yes", "--json"])
                try args.require(words: 0...0, flags: ["--yes", "--json"])
                if args.flags.contains("--yes") {
                    return try await HostCLIRelaunch.execute(
                        json: args.flags.contains("--json"), invoke: invoke)
                }
            }
            return try await core(arguments, input: input)
        }
        if arguments.starts(with: ["camera", "on"]) || arguments.starts(with: ["camera", "off"]) {
            return try await core(arguments, input: input)
        }
        if ["extensions", "invoke"].contains(command) {
            var normalized = arguments
            if command == "extensions" {
                guard arguments.filter({ $0 == "--json" }).count <= 1 else {
                    throw HostCLIError.usage("Duplicate --json flag.")
                }
                normalized.removeAll { $0 == "--json" }
                if normalized.count == 1 { normalized.append("ls") }
                if normalized.count > 1, normalized[1] == "list" { normalized[1] = "ls" }
            }
            switch try HostCLICommand.parse(normalized, readInput: { input }) {
            case .help: return try HostCLIOutput.text(HostCLICommand.usageText)
            case .request(let request):
                return try HostCLIOutput.text(
                    String(
                        decoding: HostCLI.output(try await invoke(request), raw: request.raw),
                        as: UTF8.self))
            default: throw HostCLIError.usage("Invalid extension command.")
            }
        }
        let registry: HostCLIProviderRegistry
        do { registry = try await HostCLIProviderRegistry.load(invoke: invoke) } catch {
            try Task.checkCancellation()
            guard HostCLIProviderCatalog.prefixes.values.contains(where: { $0.contains(command) })
            else { throw HostCLIError.usage("Unknown command. Run ed --help.") }
            throw error
        }
        guard
            HostCLIProviderCatalog.prefixes.values.contains(where: { $0.contains(command) })
                || registry.providers.contains(where: {
                    ($0.catalog.machineAliases ?? []).contains(command)
                })
        else { throw HostCLIError.usage("Unknown command. Run ed --help.") }
        guard
            registry.providers.contains(where: {
                $0.catalog.commands.contains { $0.route.first == command }
                    || ($0.catalog.machineAliases ?? []).contains(command)
            })
        else {
            let id =
                HostCLIProviderCatalog.prefixes.first { $0.value.contains(command) }?.key ?? command
            return try ExtensionCLIReply(
                stdout: "",
                stderr:
                    "error: the \(command) command provider is unavailable\nhint: install and enable a compatible \(id) extension with CLI support\n",
                exitCode: 4)
        }
        return try await registry.execute(
            arguments, input: input, streamWrite: streamWrite, invoke: invoke)
    }

    private func core(_ arguments: [String], input: Data) async throws -> ExtensionCLIReply {
        let timeout: Double =
            arguments.first == "camera"
            ? 120
            : arguments.starts(with: ["app", "check-updates"]) ? 65 : 30
        let data = try await invoke(
            HostCoreCLIEnvelope(arguments: arguments, input: input).request(timeout: timeout))
        let result = try JSONDecoder().decode(ExtensionCLIReply.self, from: data)
        try result.validate()
        return result
    }

    private static func ownedSettings(_ registry: HostCLIProviderRegistry?) throws
        -> [HostCLISetting]
    {
        let settings =
            HostConfigurationCLI.applicationSettings
            + (registry?.providers.flatMap { $0.catalog.settings } ?? [])
        guard Set(settings.map(\.key)).count == settings.count else {
            throw HostCLIError.rejected("Command providers disagree about setting ownership.")
        }
        return settings
    }

    private func configuration(_ arguments: [String], input: Data) async throws -> ExtensionCLIReply
    {
        if arguments.isEmpty || arguments.first?.hasPrefix("-") == true {
            return try await configuration(["ls"] + arguments, input: input)
        }
        let registry = try await HostCLIProviderRegistry.load(invoke: invoke)
        _ = try Self.ownedSettings(registry)
        let action = arguments.first ?? "ls"
        if ["get", "describe", "set", "unset"].contains(action), arguments.count >= 2 {
            let key = arguments[1]
            if HostConfigurationCLI.applicationSettings.contains(where: { $0.key == key }) {
                return try await core(["config"] + arguments, input: input)
            }
            guard
                let provider = registry.providers.first(where: {
                    $0.catalog.settings.contains { $0.key == key }
                })
            else { return try await core(["config"] + arguments, input: input) }
            return try await configProvider(provider, arguments: arguments, input: input)
        }
        if action == "import" {
            return try await importConfiguration(arguments, input: input, registry: registry)
        }
        guard ["ls", "list", "export"].contains(action) else {
            return try await core(["config"] + arguments, input: input)
        }
        let args = try HostCLIArguments(
            Array(arguments.dropFirst()), flags: ["--json", "--changed", "--defaults"],
            options: ["--group"])
        try args.require(
            words: 0...1, flags: action == "export" ? ["--defaults"] : ["--json", "--changed"],
            options: action == "export" ? [] : ["--group"])
        let group = args.options["--group"]
        let prefix = args.words.first ?? ""
        let settings = try Self.ownedSettings(registry)
        if let group, !settings.contains(where: { $0.group == group }) {
            throw HostCLIError.usage("No group named \(group).")
        }
        if !prefix.isEmpty, !settings.contains(where: { $0.key.hasPrefix(prefix) }) {
            throw HostCLIError.usage("No setting starts with \(prefix).")
        }
        var requests = arguments.filter { $0 != "--json" }
        if action != "export" { requests.append("--json") }
        if let group,
            !HostConfigurationCLI.applicationSettings.contains(where: { $0.group == group })
        {
            requests = []
        }
        var replies: [ExtensionCLIReply] = []
        if !requests.isEmpty || arguments.isEmpty {
            let coreArguments = arguments.isEmpty ? ["ls", "--json"] : requests
            replies.append(try await core(["config"] + coreArguments, input: input))
        }
        for provider in registry.providers
        where !provider.catalog.settings.isEmpty
            && (group == nil || provider.catalog.settings.contains(where: { $0.group == group }))
        {
            var providerArguments = arguments.filter { $0 != "--json" }
            if providerArguments.isEmpty { providerArguments = ["ls"] }
            if action != "export" { providerArguments.append("--json") }
            replies.append(
                try await configProvider(provider, arguments: providerArguments, input: input))
        }
        for reply in replies where reply.exitCode != 0 { return reply }
        if action == "export" {
            var document: [String: HostCLIJSON] = [:]
            for reply in replies {
                guard
                    let values = try JSONDecoder().decode(
                        HostCLIJSON.self, from: Data(reply.stdout.utf8)
                    ).object
                else { throw HostCLIError.rejected("Invalid configuration export.") }
                document.merge(values) { _, _ in .null }
            }
            return try HostCLIOutput.json(.object(document))
        }
        var rows: [HostCLIJSON] = []
        for reply in replies {
            guard
                let values = try JSONDecoder().decode(
                    HostCLIJSON.self, from: Data(reply.stdout.utf8)
                ).array
            else { throw HostCLIError.rejected("Invalid configuration listing.") }
            rows += values
        }
        rows.sort { ($0.object?["key"]?.string ?? "") < ($1.object?["key"]?.string ?? "") }
        if args.flags.contains("--json") { return try HostCLIOutput.json(.array(rows)) }
        return try HostCLIOutput.text(
            HostCLIOutput.table(
                headers: ["KEY", "GROUP", "TYPE", "VALUE"],
                rows: rows.compactMap(\.object).map {
                    [
                        ($0["key"]?.string ?? ""), ($0["group"]?.string ?? ""),
                        ($0["type"]?.string ?? ""), HostCLIOutput.text($0["value"] ?? .null),
                    ]
                }))
    }

    private func configProvider(
        _ provider: HostCLIProviderRegistry.Provider, arguments: [String], input: Data
    ) async throws -> ExtensionCLIReply {
        guard try await HostCLIProviderRegistry.states(invoke: invoke).contains(provider.state)
        else { throw HostCLIError.rejected("The settings provider changed.") }
        let data = try await invoke(
            HostCLIRequest(
                action: .invoke, id: provider.state.id,
                operation: provider.state.id + ".config.cli",
                payload: HostCLIProviderRegistry.request(
                    arguments: arguments, input: input, catalog: provider.catalog)))
        guard try await HostCLIProviderRegistry.states(invoke: invoke).contains(provider.state)
        else { throw HostCLIError.rejected("The settings provider changed before responding.") }
        let reply = try JSONDecoder().decode(ExtensionCLIReply.self, from: data)
        try reply.validate()
        return reply
    }

    private func importConfiguration(
        _ arguments: [String], input: Data, registry: HostCLIProviderRegistry
    ) async throws -> ExtensionCLIReply {
        let args = try HostCLIArguments(
            Array(arguments.dropFirst()), flags: ["--json", "--dry-run"])
        try args.require(words: 1...1, flags: ["--json", "--dry-run"])
        guard args.words == ["-"],
            let values = try JSONDecoder().decode(HostCLIJSON.self, from: input).object
        else { throw HostCLIError.usage("Import requires a JSON object from a file or stdin.") }
        let providers = registry.providers.filter { !$0.catalog.settings.isEmpty }
        let known = Set(try Self.ownedSettings(registry).map(\.key))
        var result: [String: [String]] = [
            "applied": [], "unchanged": [], "skipped": values.keys.filter { !known.contains($0) },
        ]
        let dryRun = args.flags.contains("--dry-run")
        let domains: [(HostCLIProviderRegistry.Provider?, Set<String>)] =
            [(nil, Set(HostConfigurationCLI.applicationSettings.map(\.key)))]
            + providers.map { (Optional($0), Set($0.catalog.settings.map(\.key))) }
        for (provider, keys) in domains {
            let document = values.filter { keys.contains($0.key) }
            if document.isEmpty { continue }
            let data = try HostCLIJSON.object(document).encoded()
            let preview = ["import", "-", "--json", "--dry-run"]
            let reply: ExtensionCLIReply
            if let provider {
                reply = try await configProvider(provider, arguments: preview, input: data)
            } else {
                reply = try await core(["config"] + preview, input: data)
            }
            if reply.exitCode != 0 { return reply }
        }
        for (provider, keys) in domains {
            let document = values.filter { keys.contains($0.key) }
            if document.isEmpty { continue }
            let data = try HostCLIJSON.object(document).encoded()
            let command = ["import", "-", "--json"] + (dryRun ? ["--dry-run"] : [])
            let reply: ExtensionCLIReply
            if let provider {
                reply = try await configProvider(provider, arguments: command, input: data)
            } else {
                reply = try await core(["config"] + command, input: data)
            }
            guard reply.exitCode == 0,
                let document = try JSONDecoder().decode(
                    HostCLIJSON.self, from: Data(reply.stdout.utf8)
                ).object
            else {
                throw HostCLIError.rejected(
                    "Configuration import failed after preflight; inspect current values before retrying."
                )
            }
            for name in ["applied", "unchanged", "skipped"] {
                guard let keys = document[name]?.array, keys.allSatisfy({ $0.string != nil }) else {
                    throw HostCLIError.rejected("Invalid import response.")
                }
                result[name, default: []] += keys.compactMap(\.string)
            }
        }
        if args.flags.contains("--json") {
            return try HostCLIOutput.json(
                .object(
                    result.mapValues { .strings($0.sorted()) }.merging(["dryRun": .bool(dryRun)]) {
                        first, _ in first
                    }))
        }
        let count = result["applied"]?.count ?? 0
        return try ExtensionCLIReply(
            stdout:
                "\(dryRun ? "would apply" : "applied") \(count) \(count == 1 ? "setting" : "settings")\n",
            stderr: result["skipped", default: []].isEmpty
                ? ""
                : "skipped: " + result["skipped", default: []].sorted().joined(separator: ", ")
                    + "\n", exitCode: 0)
    }

    private func complete(_ arguments: [String]) async throws -> ExtensionCLIReply {
        guard arguments.count >= 3, arguments[0] == "--index", let index = Int(arguments[1]),
            index >= 0, arguments[2] == "--"
        else { throw HostCLIError.usage("Invalid completion request.") }
        let words = Array(arguments.dropFirst(3))
        guard index <= words.count, index <= 128 else {
            throw HostCLIError.usage("Invalid completion index.")
        }
        let leading = Array(words.prefix(index).dropFirst())
        let prefix = index < words.count ? words[index] : ""
        let registry = try? await HostCLIProviderRegistry.load(invoke: invoke)
        let routes =
            HostCLIHelp.routes
            + (registry?.providers.flatMap { $0.catalog.commands.map(\.route) } ?? [])
        var candidates = routes.filter { $0.starts(with: leading) && $0.count > leading.count }.map
        { $0[leading.count] }
        if leading.count == 2, leading.first == "config",
            ["get", "set", "unset", "describe"].contains(leading[1])
        {
            candidates += try Self.ownedSettings(registry).map(\.key)
        }
        if leading.first == "extensions", leading.count == 2 {
            candidates += (try? HostIndex.bundled().map(\.id)) ?? []
        }
        if leading == ["permissions", "request"] || leading == ["permissions", "settings"] {
            candidates += [
                "calendar", "notifications", "accessibility", "inputMonitoring", "fullDisk",
                "screenRecording", "applicationAudio", "camera", "bluetooth", "automation",
            ]
        }
        if leading.isEmpty {
            candidates += registry?.providers.flatMap { $0.catalog.machineAliases ?? [] } ?? []
        }
        if let provider = registry?.providers.first(where: { provider in
            leading.first.map { word in
                provider.catalog.commands.contains { $0.route.first == word }
                    || (provider.catalog.machineAliases ?? []).contains(word)
            } ?? false
        }), let operation = provider.catalog.completionOperation {
            let payload = try HostCLIJSON.object([
                "words": .strings(words), "index": .integer(Int64(index)),
            ]).encoded()
            let data = try await invoke(
                HostCLIRequest(
                    action: .invoke, id: provider.state.id, operation: operation, payload: payload,
                    timeout: 3))
            guard try await HostCLIProviderRegistry.states(invoke: invoke).contains(provider.state),
                let object = try JSONDecoder().decode(HostCLIJSON.self, from: data).object,
                let dynamic = object["candidates"]?.array, dynamic.count <= 4096,
                dynamic.allSatisfy({
                    $0.string.map {
                        $0.utf8.count <= 4096 && !$0.contains("\n") && !$0.utf8.contains(0)
                    } == true
                }), object["wantsFiles"]?.bool != nil
            else { throw HostCLIError.rejected("Invalid or stale completion response.") }
            return try HostCLIOutput.text(
                ((object["wantsFiles"] == .bool(true) ? ["#files"] : [])
                    + dynamic.compactMap(\.string)).joined(separator: "\n"))
        }
        if leading == ["completions"] {
            candidates += ["zsh", "bash", "fish", "install", "source"]
        }
        return try HostCLIOutput.text(
            Set(candidates.filter { $0.hasPrefix(prefix) }).sorted().joined(separator: "\n"))
    }

    static func inputForCommand(
        _ arguments: [String], descriptor: Int32 = STDIN_FILENO,
        invoke: @escaping HostCLIProviderRegistry.Invoke
    ) async throws -> Data {
        try Task.checkCancellation()
        if arguments.starts(with: ["config", "import"]) {
            let parsed = try HostCLIArguments(
                Array(arguments.dropFirst(2)), flags: ["--json", "--dry-run"])
            try parsed.require(words: 1...1, flags: ["--json", "--dry-run"])
            let file = parsed.words[0]
            if file != "-" {
                let handle = try FileHandle(
                    forReadingFrom: URL(fileURLWithPath: (file as NSString).expandingTildeInPath))
                defer { try? handle.close() }
                let data =
                    try handle.read(upToCount: HostCLIInvocationContext.maximumInputBytes + 1)
                    ?? Data()
                guard data.count <= HostCLIInvocationContext.maximumInputBytes else {
                    throw HostCLIError.usage("Input exceeds 4 MiB.")
                }
                return data
            }
        }
        var declaredInput = false
        if isatty(descriptor) == 0, let command = arguments.first,
            !Self.coreCommands.contains(command)
        {
            let registry = try? await HostCLIProviderRegistry.load(invoke: invoke)
            try Task.checkCancellation()
            declaredInput =
                registry?.providers.contains { provider in
                    provider.catalog.acceptsInput == true
                        && provider.catalog.commands.contains {
                            $0.readsInput == true && arguments.starts(with: $0.route)
                        }
                } ?? false
        }
        guard
            declaredInput
                || arguments.first == "latex" && isatty(descriptor) == 0
                    && arguments.contains(where: { ["write", "edit"].contains($0) })
                || arguments.first == "jev" && isatty(descriptor) == 0
                    && arguments.contains("-")
                    && (arguments.starts(with: ["jev", "key", "set"])
                        || arguments.starts(with: ["jev", "ask"]))
                || arguments.contains("--json") && arguments.contains("-")
                || arguments.starts(with: ["config", "import"]) && arguments.contains("-")
        else { return Data() }
        guard isatty(descriptor) == 0 else { throw HostCLIError.usage("Pipe input into stdin.") }
        var data = Data()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, 100)
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0 else { throw HostCLIError.usage("Could not read stdin.") }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw HostCLIError.usage("Could not read stdin.") }
            if count == 0 { return data }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count <= HostCLIInvocationContext.maximumInputBytes else {
                throw HostCLIError.usage("Input exceeds 4 MiB.")
            }
        }
        throw HostCLIError.timedOut
    }

    public static let coreCommands = [
        "guide", "schema", "version", "status", "completions", "install", "uninstall", "config",
        "app", "permissions", "extensions", "invoke", "mcp",
    ]
    private static let help = """
        usage: ed <command> [arguments]

        core: guide schema version status completions install uninstall config app permissions
        marketplace: extensions invoke
        tools: mcp

        Feature commands are provided by compatible, enabled downloaded extensions.
        Run ed extensions ls to inspect providers, or ed guide --json for live routes.
        Extension commands preserve their original stdout, stderr, and exit codes.
        """
}
