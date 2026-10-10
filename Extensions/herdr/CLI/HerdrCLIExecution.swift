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
        let previousLayout = HerdrCLIEnvironment.layout
        let previousHooks = HerdrCLIEnvironment.hooks
        let previousSend = HerdrCLIEnvironment.send
        let previousSpace = HerdrCLIEnvironment.space
        HerdrCLIEnvironment.hooks = worker.hooks
        HerdrCLIEnvironment.send = { text, agent in
            guard !Task.isCancelled, await !worker.isStopped else {
                return .failed("The Herdr engine stopped.")
            }
            return await previousSend(text, agent)
        }
        HerdrCLIEnvironment.layout = { request in
            try await MainActor.run {
                guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
                try Task.checkCancellation()
                if let error = worker.store.performLayout(request) { throw CLIFailure(error) }
                return worker.store.layoutSnapshot()
            }
        }
        HerdrCLIEnvironment.space = { action, window, side in
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
        defer {
            HerdrCLIEnvironment.layout = previousLayout
            HerdrCLIEnvironment.hooks = previousHooks
            HerdrCLIEnvironment.space = previousSpace
            HerdrCLIEnvironment.send = previousSend
        }
        let reply = try await ExtensionCLIExecution.run(
            HerdrCLICommand.self, arguments: request.arguments)
        try Task.checkCancellation()
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        return reply
    }
}

enum HerdrCLIEnvironment {
    nonisolated(unsafe) static var collect: HerdrSessionOperationExecution.Collect = {
        await HerdrSessionOperationExecution.list($0)
    }
    nonisolated(unsafe) static var hooks = AgentHookService.shared
    nonisolated(unsafe) static var send:
        @Sendable (String, HerdrAgent) async -> HerdrPromptOutcome = {
            await HerdrAgentPrompt.send($0, to: $1)
        }
    nonisolated(unsafe) static var layout:
        @Sendable (HerdrLayoutRequest) async throws -> HerdrLayoutSnapshot = { _ in
            throw CLIFailure.unavailable("the Herdr engine is unavailable")
        }
    nonisolated(unsafe) static var space:
        @Sendable (String, String?, String?) async throws -> (
            windows: [[String: Any]], message: String?
        ) = { _, _, _ in
            throw CLIFailure.unavailable("the Herdr engine is unavailable")
        }
    nonisolated(unsafe) static var launchTerminal:
        @Sendable (TerminalLaunchRequest) async throws -> Int32 = { _ in
            throw CLIFailure.unavailable(
                "foreground terminal transport is unavailable",
                hint: "use the embedded Herdr terminal")
        }
}
