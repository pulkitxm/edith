import AppKit
import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

struct BrowserCLIConfiguration: @unchecked Sendable {
    let request: @MainActor (NotchBrowserRequest) async throws -> NotchBrowserSnapshot
    let copy: @MainActor (String) throws -> Void
}

enum BrowserCLIEnvironment {
    @TaskLocal static var configuration: BrowserCLIConfiguration?
}

@MainActor enum BrowserCLIExecution {
    static func configuration(
        request: @escaping @MainActor (NotchBrowserRequest) async throws -> NotchBrowserSnapshot,
        copy: @escaping @MainActor (String) throws -> Void = { link in
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(link, forType: .string) else {
                throw CLIFailure("could not copy the address to the clipboard")
            }
        }
    ) -> BrowserCLIConfiguration { .init(request: request, copy: copy) }

    static func run(
        _ input: ExtensionCLIRequest,
        request: @escaping @MainActor (NotchBrowserRequest) async throws -> NotchBrowserSnapshot,
        copy: @escaping @MainActor (String) throws -> Void = { link in
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(link, forType: .string) else {
                throw CLIFailure("could not copy the address to the clipboard")
            }
        }
    ) async throws -> ExtensionCLIReply {
        try await BrowserCLIEnvironment.$configuration.withValue(
            configuration(request: request, copy: copy)
        ) { try await ExtensionCLIExecution.run(BrowserCommand.self, request: input) }
    }
}

@MainActor enum NotchCLIProviderCatalog {
    static func encode(_ payload: Data) throws -> Data {
        guard payload == Data("{}".utf8) else { throw ExtensionPeerError.invalidRequest }
        let parsers = [
            (ShelfCommand._dumpHelp(), "notch.cli"), (BrowserCommand._dumpHelp(), "browser.cli"),
        ]
        var commands: [[String: Any]] = []
        var help: [[String: Any]] = []
        for (document, operation) in parsers {
            guard
                let parser = try JSONSerialization.jsonObject(with: Data(document.utf8))
                    as? [String: Any],
                let root = parser["command"] as? [String: Any]
            else { throw ExtensionPeerError.invalidRequest }
            help.append(parser)
            func append(_ node: [String: Any], route: [String]) throws {
                guard let name = node["commandName"] as? String,
                    let summary = node["abstract"] as? String, !summary.isEmpty,
                    !name.isEmpty, name.utf8.count <= 80, route.count < 12
                else { throw ExtensionPeerError.invalidRequest }
                let next = route + [name]
                commands.append([
                    "route": next, "operation": operation, "streamOperation": operation,
                    "streamDeadline": 30, "summary": summary, "timeout": 30,
                    "destructive": Set([
                        "close", "close-others", "close-right", "detach", "remove", "clear",
                    ]).contains(name),
                    "readsInput": false, "jsonOutput": false,
                ])
                for child in node["subcommands"] as? [[String: Any]] ?? [] {
                    try append(child, route: next)
                }
            }
            try append(root, route: [])
        }
        guard commands.count <= 128 else { throw ExtensionPeerError.invalidRequest }
        return try JSONSerialization.data(
            withJSONObject: [
                "version": 1, "owner": "notchShelf", "commands": commands,
                "settings": [], "acceptsInput": true, "parserHelp": help,
            ], options: [.sortedKeys])
    }
}
