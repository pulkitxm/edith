import ArgumentParser
import EdithKit
import Foundation

struct BifrostCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bifrost",
        abstract: "The launcher bar, the applications it knows and the answers it gives.",
        subcommands: [
            BifrostOpenCommand.self, BifrostListCommand.self, BifrostCalcCommand.self,
            BifrostConvertCommand.self, BifrostReindexCommand.self, BifrostClearCommand.self,
        ],
        defaultSubcommand: BifrostListCommand.self)
}

enum BifrostBridge {
    static func requireExtension() throws {
        guard
            CLIEnvironment.sharedDefaults.object(forKey: AppStorageKeys.Bifrost.enabled) as? Bool
                == true
        else {
            throw CLIFailure.unavailable(
                "the Bifrost extension is off",
                hint: "run `ed extensions enable bifrost`, then retry")
        }
    }

    static func index() throws -> BifrostIndex {
        guard let index = BifrostIndexStore.shared.load(), index.isUsable else {
            throw CLIFailure.notFound(
                "no applications are indexed yet",
                hint: "run `ed bifrost reindex` with Edith running")
        }
        return index
    }
}

struct BifrostOpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open", abstract: "Open the Bifrost launcher bar.")

    @Argument(help: "Text to put in the bar before it opens.")
    var query: String?

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            try BifrostBridge.requireExtension()
            try AppBridge.requireHelper("opening the launcher")
            let text = query ?? ""
            let descriptor = BifrostOperationExecution.request(
                .open, userInfo: BifrostPanelIPC.openPayload(query: text)
            ) { name, info in
                AppBridge.post(name, userInfo: info)
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "operation": .string(descriptor.id.rawValue),
                        "requested": .bool(true),
                        "query": .string(text),
                    ]))
                return
            }
            CLIOut.out("launcher requested")
        }
    }
}

struct BifrostListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List the applications Bifrost has indexed.",
        aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Rank the index against this query, exactly as the bar does.")
    var search: String?

    @Option(help: "Show at most this many applications.")
    var limit: Int = 50

    func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.nonNegative(self.limit, "--limit")
            let index = try BifrostBridge.index()
            let matches = select(from: index, limit: limit)
            guard !json else {
                CLIOut.json(
                    .array(
                        matches.map { application in
                            .object([
                                "name": .string(application.name),
                                "path": .string(application.path),
                                "bundleID": application.bundleID.map { .string($0) } ?? .null,
                            ])
                        }))
                return
            }
            guard !matches.isEmpty else {
                CLIOut.note("no application matches")
                return
            }
            for application in matches { CLIOut.out("\(application.name)  \(application.path)") }
        }
    }

    private func select(from index: BifrostIndex, limit: Int) -> [BifrostApplication] {
        guard let search, !search.isEmpty else {
            return limit == 0 ? index.applications : Array(index.applications.prefix(limit))
        }
        let ledger = BifrostUsageLedger.load(
            from: CLIEnvironment.sharedDefaults, key: AppStorageKeys.Bifrost.usage)
        let ranked = BifrostQuery.matches(
            query: search, applications: index.applications, ledger: ledger, now: Date(),
            limit: limit == 0 ? index.applications.count : limit)
        let byPath = Dictionary(
            index.applications.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var found: [BifrostApplication] = []
        for result in ranked {
            guard case .launch(let path) = result.action, let application = byPath[path] else {
                continue
            }
            found.append(application)
        }
        return found
    }
}

struct BifrostCalcCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calc", abstract: "Evaluate an expression the way the bar does.")

    @Argument(help: "The expression, for example \"12 * 8 + 4%\".")
    var expression: String

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            guard let calculation = BifrostCalculator.evaluate(expression) else {
                throw CLIFailure.notFound(
                    "\(expression) is not an expression Bifrost can evaluate",
                    hint: "try a sum such as `ed bifrost calc \"2 + 2\"`")
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "expression": .string(calculation.expression),
                        "value": .double(calculation.value),
                        "display": .string(calculation.display),
                    ]))
                return
            }
            CLIOut.out(calculation.copyText)
        }
    }
}

struct BifrostConvertCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "convert", abstract: "Convert between units the way the bar does.")

    @Argument(help: "The conversion, for example \"12 km in miles\".")
    var sentence: String

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            guard let conversion = BifrostConversionParser.parse(sentence) else {
                throw CLIFailure.notFound(
                    "\(sentence) is not a conversion Bifrost understands",
                    hint: "try `ed bifrost convert \"12 km in miles\"`")
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "value": .double(conversion.value),
                        "from": .string(conversion.source.id),
                        "to": .string(conversion.target.id),
                        "result": .double(conversion.result),
                        "display": .string(conversion.display),
                        "dimension": .string(conversion.source.dimension.rawValue),
                    ]))
                return
            }
            CLIOut.out(conversion.detail)
        }
    }
}

struct BifrostReindexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reindex", abstract: "Rebuild the Bifrost application index.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            try BifrostBridge.requireExtension()
            try AppBridge.requireHelper("rebuilding the application index")
            let descriptor = BifrostOperationExecution.request(.reindex) { name, info in
                AppBridge.post(name, userInfo: info)
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "operation": .string(descriptor.id.rawValue),
                        "requested": .bool(true),
                    ]))
                return
            }
            CLIOut.out("index rebuild requested")
        }
    }
}

struct BifrostClearCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear", abstract: "Forget what Bifrost ranks as frequently opened.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            var ledger = BifrostUsageLedger.load(
                from: CLIEnvironment.sharedDefaults, key: AppStorageKeys.Bifrost.usage)
            let removed = ledger.entries.count
            ledger.clear()
            ledger.save(to: CLIEnvironment.sharedDefaults, key: AppStorageKeys.Bifrost.usage)
            AppBridge.post(IPC.Name.settingsChanged)
            guard !json else {
                CLIOut.json(.object(["cleared": .int(removed)]))
                return
            }
            CLIOut.out("cleared \(removed) frequently opened applications")
        }
    }
}
