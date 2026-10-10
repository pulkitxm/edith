import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum HerdrCLIExecution {
    static func run(_ request: ExtensionCLIRequest, worker: HerdrWorker) async throws
        -> ExtensionCLIReply
    {
        try request.validate()
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        if worker.automaticActions, worker.store.hosts.isEmpty { await worker.store.refresh() }
        try Task.checkCancellation()
        let context = makeContext(worker: worker)
        let reply = try await OwnedTerminalContext.$registry.withValue(worker.terminalSessions) {
            try await HerdrCLIEnvironment.$context.withValue(context) {
                try await HerdrLaunchCatalogContext.$catalog.withValue(worker.catalogs) {
                    try await ExtensionCLIExecution.run(HerdrCLICommand.self, request: request)
                }
            }
        }
        try Task.checkCancellation()
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        return reply
    }

    static func invokeStream(
        _ operation: String, payload: Data, worker: HerdrWorker,
        streams: ExtensionCLIStreams
    ) throws -> Data {
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        return try OwnedTerminalContext.$registry.withValue(worker.terminalSessions) {
            return try HerdrCLIEnvironment.$context.withValue(makeContext(worker: worker)) {
                try HerdrLaunchCatalogContext.$catalog.withValue(worker.catalogs) {
                    try streams.invoke(
                        HerdrCLICommand.self, operation: operation,
                        prefix: "herdr.cli", payload: payload)
                }
            }
        }
    }

    private static func makeContext(worker: HerdrWorker) -> HerdrCLIEnvironment.Context {
        let previousSend = HerdrCLIEnvironment.send
        let send: HerdrCLIEnvironment.Sender = { text, agent in
            guard !Task.isCancelled, await !worker.isStopped else {
                return .failed("The Herdr engine stopped.")
            }
            return await previousSend(text, agent)
        }
        let layout: HerdrCLIEnvironment.Layout = { request in
            try await MainActor.run {
                guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
                try Task.checkCancellation()
                if let error = worker.store.performLayout(request) { throw CLIFailure(error) }
                return worker.store.layoutSnapshot()
            }
        }
        let space: HerdrCLIEnvironment.Space = { action, window, side in
            try await MainActor.run {
                guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
                try Task.checkCancellation()
                let windows: [HerdrSpaceWindow.Info]
                let message: String?
                switch action {
                case "list": windows = HerdrSpaceWindow.listed(); message = nil
                case "terminal":
                    guard let opened = HerdrSpaceWindow.openTerminal(window) else {
                        throw CLIFailure.notFound(HerdrSpaceWindow.missing(window))
                    }
                    windows = [opened]; message = "opened a terminal"
                case "split":
                    guard let insert = InsertSide(rawValue: side ?? "right"),
                        let opened = HerdrSpaceWindow.split(window, side: insert)
                    else { throw CLIFailure.notFound(HerdrSpaceWindow.missing(window)) }
                    windows = [opened]; message = "split \(side ?? "right")"
                default: throw CLIFailure.usage("unknown space action")
                }
                return (
                    windows.map {
                        ["id": $0.id, "title": $0.title, "tabs": $0.tabs, "panes": $0.panes]
                    }, message
                )
            }
        }
        return HerdrCLIEnvironment.Context(
            hooks: worker.hooks, send: send, layout: layout, space: space)
    }
}

enum HerdrCLIEnvironment {
    typealias Sender = @Sendable (String, HerdrAgent) async -> HerdrPromptOutcome
    typealias Layout = @Sendable (HerdrLayoutRequest) async throws -> HerdrLayoutSnapshot
    typealias Space =
        @Sendable (String, String?, String?) async throws -> (
            windows: [[String: Any]], message: String?
        )
    struct Context: Sendable {
        let hooks: AgentHookService
        let send: Sender
        let layout: Layout
        let space: Space
    }
    @TaskLocal static var context: Context?

    nonisolated(unsafe) static var collect: HerdrSessionOperationExecution.Collect = {
        await HerdrSessionOperationExecution.list($0)
    }
    static var hooks: AgentHookService { context?.hooks ?? AgentHookService.shared }
    static var send: Sender {
        if let context { return context.send }
        return { await HerdrAgentPrompt.send($0, to: $1) }
    }
    static var layout: Layout {
        if let context { return context.layout }
        return { _ in throw CLIFailure.unavailable("the Herdr engine is unavailable") }
    }
    static var space: Space {
        if let context { return context.space }
        return { _, _, _ in
            throw CLIFailure.unavailable("the Herdr engine is unavailable")
        }
    }
    nonisolated(unsafe) static var launchTerminal:
        @Sendable (TerminalLaunchRequest) async throws -> Int32 = { _ in
            throw CLIFailure.unavailable(
                "foreground terminal transport is unavailable",
                hint: "use the embedded Herdr terminal")
        }
}
