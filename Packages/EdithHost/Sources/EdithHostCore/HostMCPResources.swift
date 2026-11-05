import Foundation

enum HostMCPResources {
    static let catalogToolName = "edith_catalog"

    static let guideTopics: [(path: String, title: String, summary: String, text: String)] = [
        (
            "guide", "ed manual",
            "The full ed manual: command families, conventions, exit codes and examples.",
            HostGuideCLI.text
        ),
        (
            "guide/agent", "ed instructions for agents",
            "Short repository instructions that make an agent ed-aware.", HostGuideCLI.agentSnippet
        ),
        (
            "guide/mcp", "Edith over MCP",
            "How an agent should discover, install and call Edith's tools.", HostGuideCLI.mcpText
        ),
    ]

    static let catalogTool: HostCLIJSON = .object([
        "name": .string(catalogToolName),
        "title": .string("Edith extension catalog"),
        "description": .string(
            "Start here. Lists every Edith extension with whether it is installed or enabled, its tagline, summary and example ed commands. Filter with query or status, or pass id for one extension's full guide. Extensions that are available but not installed have no tools yet: install one with edith_extensions_install."
        ),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"), "maxLength": .integer(200),
                    "description": .string("Words to match against names, taglines and summaries."),
                ]),
                "status": .object([
                    "type": .string("string"),
                    "enum": .strings(["all", "installed", "available"]),
                ]),
                "id": .object([
                    "type": .string("string"), "maxLength": .integer(80),
                    "description": .string("Return only this extension, with its steps."),
                ]),
            ]),
            "additionalProperties": .bool(false),
        ]),
        "annotations": .object(["readOnlyHint": .bool(true)]),
    ])

    static func uri(_ path: String) -> String { "edith://" + path }

    static func list(_ index: [HostExtension]) -> HostCLIJSON {
        let topics = guideTopics.map {
            HostCLIJSON.object([
                "uri": .string(uri($0.path)),
                "name": .string($0.path.replacingOccurrences(of: "/", with: "-")),
                "title": .string($0.title), "description": .string($0.summary),
                "mimeType": .string("text/markdown"),
            ])
        }
        let extensions = index.sorted { $0.id < $1.id }.map {
            HostCLIJSON.object([
                "uri": .string(uri("extensions/" + $0.id)), "name": .string($0.id),
                "title": .string($0.title + " guide"),
                "description": .string($0.guide?.tagline ?? $0.title),
                "mimeType": .string("text/markdown"),
            ])
        }
        return .object(["resources": .array(topics + extensions)])
    }

    static func read(_ uri: String, index: [HostExtension]) -> HostCLIJSON? {
        let text: String
        if let topic = guideTopics.first(where: { Self.uri($0.path) == uri }) {
            text = topic.text
        } else if uri.hasPrefix(Self.uri("extensions/")),
            let entry = index.first(where: { Self.uri("extensions/" + $0.id) == uri })
        {
            text = markdown(entry)
        } else {
            return nil
        }
        return .object([
            "contents": .array([
                .object([
                    "uri": .string(uri), "mimeType": .string("text/markdown"),
                    "text": .string(text),
                ])
            ])
        ])
    }

    static func markdown(_ entry: HostExtension) -> String {
        var lines = ["# " + entry.title, ""]
        if let guide = entry.guide {
            lines += [guide.tagline, "", guide.summary]
            if !guide.steps.isEmpty {
                lines += ["", "## How to start", ""]
                lines += guide.steps.enumerated().map {
                    "\($0.offset + 1). **\($0.element.title)**: \($0.element.detail)"
                }
            }
            if !guide.examples.isEmpty {
                lines += ["", "## Examples", ""] + guide.examples.map { "- `\($0)`" }
            }
        }
        if !entry.commands.isEmpty {
            lines += ["", "## Commands", ""] + entry.commands.map { "- `ed \($0)`" }
        }
        lines += [
            "", "## From an agent", "",
            "- `edith_catalog` with `{\"id\": \"\(entry.id)\"}` shows whether it is installed.",
            "- `edith_extensions_install` with `{\"arguments\": [\"\(entry.id)\"]}` installs it after confirmation.",
            "- `edith_app_navigate` with `{\"arguments\": [\"\(entry.id)\"]}` shows its page to the user.",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    static func status(_ info: [String: HostCLIJSON]?) -> String {
        guard let info else { return "unknown" }
        if info["installed"]?.bool == true {
            return info["enabled"]?.bool == true ? "enabled" : "installed"
        }
        return info["compatible"]?.bool == true ? "available" : "unavailable"
    }

    static func entry(
        _ extensionEntry: HostExtension, info: [String: HostCLIJSON]?, detailed: Bool
    ) -> HostCLIJSON {
        let guide = extensionEntry.guide
        var object: [String: HostCLIJSON] = [
            "id": .string(extensionEntry.id), "title": .string(extensionEntry.title),
            "category": .string(extensionEntry.category),
            "status": .string(status(info)),
            "tagline": .string(guide?.tagline ?? extensionEntry.title),
            "summary": .string(guide?.summary ?? ""),
            "examples": .strings(guide?.examples ?? []),
            "commands": .strings(extensionEntry.commands.map { "ed " + $0 }),
            "guide": .string(uri("extensions/" + extensionEntry.id)),
        ]
        if info?["updateAvailable"]?.bool == true { object["updateAvailable"] = .bool(true) }
        if detailed {
            object["steps"] = .array(
                (guide?.steps ?? []).map {
                    .object(["title": .string($0.title), "detail": .string($0.detail)])
                })
        }
        return .object(object)
    }
}

extension HostMCPCLI {
    func catalog(_ arguments: [String: HostCLIJSON]) async throws -> HostCLIJSON {
        guard Set(arguments.keys).isSubset(of: ["query", "status", "id"]),
            arguments["query"] == nil || arguments["query"]?.string != nil,
            arguments["id"] == nil || arguments["id"]?.string != nil,
            arguments["status"] == nil
                || ["all", "installed", "available"].contains(arguments["status"]?.string ?? "")
        else { throw HostCLIError.usage("Invalid catalog arguments.") }
        var states: [String: [String: HostCLIJSON]] = [:]
        var appRunning = true
        do {
            let data = try await invoke(HostCLIRequest(action: .ls))
            for item in try JSONDecoder().decode([HostCLIJSON].self, from: data) {
                if let object = item.object, let id = object["id"]?.string { states[id] = object }
            }
        } catch is CancellationError { throw CancellationError() } catch { appRunning = false }
        let id = arguments["id"]?.string
        let words = (arguments["query"]?.string ?? "").lowercased().split(separator: " ")
        let wanted = arguments["status"]?.string ?? "all"
        let entries = index().sorted { $0.id < $1.id }.filter { item in
            if let id { return item.id == id }
            let status = HostMCPResources.status(states[item.id])
            if wanted == "installed", status != "installed", status != "enabled" { return false }
            if wanted == "available", status == "installed" || status == "enabled" { return false }
            let haystack = [
                item.id, item.title, item.category, item.guide?.tagline, item.guide?.summary,
            ]
            .compactMap { $0 }.joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        if let id, entries.isEmpty {
            return .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(
                            "No extension has the id \(id). Call edith_catalog without id, or with query, to find it."
                        ),
                    ])
                ]), "isError": .bool(true),
            ])
        }
        var document: [String: HostCLIJSON] = [
            "extensions": .array(
                entries.map {
                    HostMCPResources.entry($0, info: states[$0.id], detailed: id != nil)
                }),
            "next": .string(
                "Install an available extension with edith_extensions_install (arguments: [id], confirm true after the user agrees). Installed extensions expose their commands as edith_* tools."
            ),
        ]
        if !appRunning {
            document["note"] = .string("Edith could not be reached, so install state is unknown.")
        }
        let value = HostCLIJSON.object(document)
        return .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(String(decoding: try value.encoded(), as: UTF8.self)),
                ])
            ]), "structuredContent": value, "isError": .bool(false),
        ])
    }
}

extension HostMCPCLI {
    static let instructions = """
        Edith is a macOS app built from extensions. This server lets you drive it. Work in this order:
        1. Discover. Call edith_catalog first. It lists every extension, whether it is enabled, installed \
        or available, what it does, and example ed commands. Pass query to search, or id for one extension's steps.
        2. Call. Use the matching edith_* tool. Command tools take {"arguments": [...]} holding the words that \
        follow the command on the ed command line, so `ed usage limits --refresh` is edith_usage_limits \
        with {"arguments": ["--refresh"]}. They return the command's JSON.
        3. Install only when needed. Tools exist only for enabled extensions. If the one you need is available, \
        ask the user, then call edith_extensions_install with {"arguments": ["<id>"], "confirm": true}. Without \
        confirm it only previews. The server then sends notifications/tools/list_changed, so list tools again.
        Commands that change or remove something also preview until confirm is true; never put --yes in arguments. \
        Call edith_app_navigate with {"arguments": ["<id>"]} to show the user an extension. More help: the \
        edith://guide/mcp, edith://extensions/<id> and edith://guide resources.
        """
}
