import ArgumentParser
import Foundation
import Testing

@testable import EdithCLI

enum CLIHelpQuality {
    static let jsonExemptions: [String: String] = [
        "ed schema": "stdout is already one JSON Schema document",
        "ed config export": "stdout is already the settings JSON document",
        "ed attention rules export": "stdout is already the attention rules JSON document",
        "ed completions zsh": "prints a zsh completion script",
        "ed completions bash": "prints a bash completion script",
        "ed completions fish": "prints a fish completion script",
        "ed mcp": "speaks MCP on stdout for the life of the process",
        "ed database mcp": "speaks MCP on stdout for the life of the process",
        "ed herdr bridge": "long-lived stdio bridge to a Herdr pane",
        "ed __complete": "hidden shell completer, not a data command",
        "ed machines exec": "streams a remote process and both byte streams",
        "ed machines docker shell": "attaches an interactive container shell",
    ]

    static let verbs: Set<String> = [
        "accept", "act", "add", "answer", "apply", "ask", "assign", "attach", "attribute",
        "audit", "back", "bridge", "broadcast", "bring", "browse", "build", "cache",
        "caffeinate", "calculate", "calibrate", "cancel", "caption", "capture", "categorize",
        "change", "check", "choose", "clean", "clear", "clone", "close", "collect", "compare",
        "complete", "compute", "configure", "confirm", "connect", "control", "convert", "copy",
        "correct", "corroborate", "count", "create", "crop", "declare", "decode", "delete",
        "deploy", "describe", "detect", "diagnose", "diff", "disable", "disconnect", "discover",
        "distill", "download", "drive", "drop", "dump", "duplicate", "edit", "embed", "emit",
        "empty", "enable", "encode", "end", "equalize", "erase", "evaluate", "execute",
        "explain", "export", "extract", "favorite", "fetch", "filter", "find", "finish",
        "focus", "follow", "forget", "forward", "frame", "freeze", "gather", "generate", "go",
        "grant", "group", "guide", "hide", "identify", "import", "index", "ingest", "inquire",
        "insert", "inspect", "install", "join", "jump", "keep", "kill", "launch", "let", "link",
        "list", "load", "lock", "make", "match", "measure", "merge", "migrate", "mount", "move",
        "mute", "normalize", "notify", "open", "order", "override", "package", "parse", "pass",
        "pause", "perform", "pick", "pin", "plan", "play", "point", "power", "prevent",
        "preview", "print", "probe", "prune", "publish", "pull", "purge", "push", "put",
        "query", "queue", "quit", "rank", "read", "reboot", "rebuild", "reclaim", "recollect",
        "record", "reflect", "refresh", "register", "reject", "release", "relink", "remove",
        "render", "rename", "reopen", "reorder", "repeat", "replace", "report", "request",
        "rescan", "reserve", "reset", "resolve", "restart", "restore", "retire", "return",
        "reveal", "review", "rewrite", "rotate", "run", "sample", "save", "say", "scan",
        "schedule", "search", "seek", "select", "send", "serve", "set", "share", "show", "shut",
        "shuffle", "skip", "snap", "split", "start", "stop", "store", "stream", "summarize",
        "swap", "switch", "sync", "take", "talk", "test", "throw", "toggle", "track",
        "transfer", "trash", "trim", "turn", "type", "undo", "uninstall", "unlink", "unmount",
        "unpin", "unregister", "unset", "update", "upgrade", "upload", "validate", "verify",
        "wake", "watch", "wipe", "write", "zoom",
    ]

    static let adverbs: Set<String> = ["atomically", "automatically", "manually"]

    struct Finding: Comparable {
        let label: String
        let issues: [String]

        var line: String { "\(label)\t\(issues.joined(separator: ", "))" }

        static func < (lhs: Finding, rhs: Finding) -> Bool { lhs.label < rhs.label }
    }

    static func findings() -> [Finding] {
        let walks = CommandCrawler.every()
        return walks.compactMap { walk in
            let issues = issues(for: walk)
            return issues.isEmpty ? nil : Finding(label: walk.label, issues: issues)
        }
    }

    static func issues(for walk: CommandWalk) -> [String] {
        let configuration = walk.type.configuration
        var issues: [String] = []
        if !abstractIsSpecific(configuration.abstract, path: walk.path) {
            issues.append("vague-abstract")
        }
        let discussion = configuration.discussion
        let prose = prose(of: discussion, path: walk.path)
        if prose.count < 40 { issues.append("discussion") }
        if discussion.range(
            of: #"(?i)(\breads\b|\bchanges\b|\bwrites\b|\bdoes not change\b)"#,
            options: .regularExpression) == nil
        {
            issues.append("effect")
        }
        if !hasExample(discussion, path: walk.path) { issues.append("example") }
        if configuration.subcommands.isEmpty, jsonExemptions[walk.label] == nil,
            !CommandCrawler.optionNames(of: walk.type).contains("--json")
        {
            issues.append("no-json")
        }
        let missing = undocumentedSynopses(CommandCrawler.help(walk.type))
        issues.append(contentsOf: missing.map { "undoc:\($0)" }.sorted())
        return issues
    }

    static func abstractIsSpecific(_ abstract: String, path: [String]) -> Bool {
        let words = tokens(abstract)
        guard !words.isEmpty else { return false }
        if words[0] == "manage" { return false }
        let pathWords = Set(path.flatMap { tokens($0) })
        let stops: Set<String> = [
            "a", "an", "and", "ed", "for", "from", "its", "of", "the", "to",
        ]
        let informative = words.filter { !stops.contains($0) && !pathWords.contains($0) }
        guard !informative.isEmpty else { return false }
        if adverbs.contains(words[0]), words.count > 1, isVerb(words[1]) { return true }
        return words.prefix(4).contains(where: isVerb)
    }

    static func isVerb(_ word: String) -> Bool {
        if verbs.contains(word) { return true }
        if word.hasSuffix("s"), verbs.contains(String(word.dropLast())) { return true }
        if word.hasSuffix("es"), verbs.contains(String(word.dropLast(2))) { return true }
        if word.hasSuffix("ed") {
            let stem = String(word.dropLast(2))
            if verbs.contains(stem) || verbs.contains(stem + "e") { return true }
        }
        if word.hasSuffix("ing"), word.count > 4 {
            let stem = String(word.dropLast(3))
            if verbs.contains(stem) || verbs.contains(stem + "e") { return true }
            if stem.count >= 2 {
                let chars = Array(stem)
                if chars[chars.count - 1] == chars[chars.count - 2],
                    verbs.contains(String(chars.dropLast()))
                {
                    return true
                }
            }
        }
        return false
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func hasExample(_ discussion: String, path: [String]) -> Bool {
        let pattern: String
        if path == ["ed"] {
            pattern = #"(?m)(^|[\s`])ed\s+[a-z]"#
        } else {
            let invocation = NSRegularExpression.escapedPattern(for: path.joined(separator: " "))
            pattern = "(?m)(^|[\\s`])\(invocation)(?=$|[\\s`])"
        }
        return discussion.range(of: pattern, options: .regularExpression) != nil
    }

    static func prose(of discussion: String, path: [String]) -> String {
        let pattern: String
        if path == ["ed"] {
            pattern = #"(?m)(^|[\s`])ed\s+\S[^\n`]*"#
        } else {
            let invocation = NSRegularExpression.escapedPattern(for: path.joined(separator: " "))
            pattern = "(?m)(^|[\\s`])\(invocation)[^\\n`]*"
        }
        let stripped = discussion.replacingOccurrences(
            of: pattern, with: " ", options: .regularExpression)
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func undocumentedSynopses(_ help: String) -> [String] {
        let lines = help.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var section = ""
        var missing: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let header = sectionHeader(line) {
                section = header
                index += 1
                continue
            }
            if acceptsInputs(section), line.hasPrefix("  "), !line.hasPrefix("   ") {
                var parts = splitDeclaration(line)
                if parts.help.isEmpty, index + 1 < lines.count, lines[index + 1].hasPrefix("   ") {
                    parts.help = lines[index + 1].trimmingCharacters(in: .whitespaces)
                }
                if isMissingHelp(parts.help) {
                    missing.append(parts.synopsis)
                }
            }
            index += 1
        }
        return missing
    }

    static func sectionHeader(_ line: String) -> String? {
        guard !line.hasPrefix(" "), line.hasSuffix(":"), line == line.uppercased(), line.count > 1
        else { return nil }
        return String(line.dropLast())
    }

    static func acceptsInputs(_ section: String) -> Bool {
        !section.isEmpty && !section.contains("SUBCOMMAND")
    }

    static func splitDeclaration(_ line: String) -> (synopsis: String, help: String) {
        let body = line.dropFirst(2)
        var index = body.startIndex
        var synopsisEnd = body.startIndex
        while index < body.endIndex {
            if body[index] == " " {
                let spaces = body[index...].prefix { $0 == " " }
                if spaces.count >= 2 { break }
                let after = body.index(index, offsetBy: spaces.count)
                if after == body.endIndex { break }
                let token = body[after...].prefix { $0 != " " }
                if !isSynopsisToken(String(token)) { break }
                index = after
                continue
            }
            let token = body[index...].prefix { $0 != " " }
            if !isSynopsisToken(String(token)) { break }
            synopsisEnd = body.index(index, offsetBy: token.count)
            index = synopsisEnd
        }
        let synopsis = String(body[..<synopsisEnd])
        let help = String(body[index...]).trimmingCharacters(in: .whitespaces)
        return (synopsis, help)
    }

    static func isSynopsisToken(_ token: String) -> Bool {
        if token == "," { return true }
        if token.hasPrefix("-") { return true }
        if token.hasPrefix("<"), token.hasSuffix(">") { return true }
        if token.hasPrefix("["), token.hasSuffix("]") { return true }
        return false
    }

    static func isMissingHelp(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        let pattern = #"\((default|values|default as flag): [^)]*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let cleared = regex.stringByReplacingMatches(
            in: trimmed, range: range, withTemplate: "")
        return cleared.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

@Suite struct CLIHelpQualityTests {
    @Test func everyCommandDocumentsItsHelp() {
        let current = CLIHelpQuality.findings().map(\.line).sorted()
        #expect(current.isEmpty, "these commands are deficient: \(current)")
    }

    @Test func jsonExemptionsAreStreamingOrAlreadyStructured() throws {
        let walks = Dictionary(
            uniqueKeysWithValues: CommandCrawler.every().map { ($0.label, $0) })
        for (label, reason) in CLIHelpQuality.jsonExemptions {
            #expect(!reason.isEmpty, "\(label) needs a reason")
            let walk = try #require(walks[label], "\(label) is not a command")
            #expect(
                walk.type.configuration.subcommands.isEmpty,
                "\(label) is a group, so it does not need a JSON exemption")
            #expect(
                !CommandCrawler.optionNames(of: walk.type).contains("--json"),
                "\(label) already has --json, so drop the exemption")
        }
    }

    @Test func theGuideMapsFamiliesConventionsAndDiscovery() {
        let guide = Guide.text
        let required = [
            "Command families",
            "ed config",
            "ed machines",
            "ed companion",
            "ed database",
            "ed studio",
            "ed herdr",
            "ed quinjet",
            "CLIDestructivePlan",
            "--yes",
            "0 success",
            "1 failure",
            "2 bad usage",
            "3 not found",
            "4 unavailable",
            "--json",
            "--machine",
            "local",
            "Discover more",
            "ed --help",
            "ed <command> --help",
            "ed guide --json",
            "ed docs ask",
        ]
        for phrase in required {
            #expect(guide.contains(phrase), "the guide never mentions \(phrase)")
        }
        #expect(Guide.agentSnippet.contains("CLIDestructivePlan"))
        #expect(!guide.contains("\u{2014}"))
        #expect(!Guide.agentSnippet.contains("\u{2014}"))
    }
}
