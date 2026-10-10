import EdithExtensionSupport
import Foundation

@MainActor public struct HostAppCommandCLI {
    public typealias Perform =
        @MainActor @Sendable (String, [String: HostCLIJSON]) async throws -> HostCLIJSON
    private let perform: Perform
    private let available: @MainActor () -> Set<String>

    public init(available: Set<String>, perform: @escaping Perform) {
        self.available = { available }; self.perform = perform
    }

    public init(available: @escaping @MainActor () -> Set<String>, perform: @escaping Perform) {
        self.available = available; self.perform = perform
    }

    public func execute(_ arguments: [String]) async throws -> ExtensionCLIReply {
        var args = try HostCLIArguments(
            arguments, flags: ["--json", "--yes", "--list", "--no-wait"],
            options: ["--dir", "--tab", "--limit"])
        let requested = args.words.isEmpty ? "actions" : args.words.removeFirst()
        let action = requested == "ls" ? "actions" : requested
        let json = args.flags.contains("--json")
        if action == "actions" {
            try args.require(words: 0...0, flags: ["--json"])
            let rows = Self.oneShotActions.map { name, summary, needs -> HostCLIJSON in
                .object([
                    "action": .string(name), "summary": .string(summary),
                    "needs": .string(needs), "available": .bool(available().contains(name)),
                ])
            }
            return json
                ? try HostCLIOutput.json(.array(rows))
                : try HostCLIOutput.text(
                    HostCLIOutput.table(
                        headers: ["ACTION", "NEEDS", "STATE", "WHAT"],
                        rows: rows.compactMap(\.object).map {
                            [
                                $0["action"]?.string ?? "", $0["needs"]?.string ?? "",
                                $0["available"]?.bool == true ? "ready" : "unavailable",
                                $0["summary"]?.string ?? "",
                            ]
                        }))
        }
        guard Self.actions.contains(action), available().contains(action) else {
            throw HostCLIError.rejected("This app installation does not provide \(action).")
        }
        var payload: [String: HostCLIJSON] = [:]
        switch action {
        case "navigate", "open-path", "open-link":
            try args.require(words: 1...1, flags: ["--json"])
            if action == "navigate" {
                let route = args.words[0]
                guard !route.isEmpty, route.utf8.count <= 4096,
                    route.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                        !$0.isEmpty
                    })
                else { throw HostCLIError.usage("Route is empty or malformed.") }
                payload["route"] = .string(route)
            } else {
                payload["id"] = .string(args.words[0])
            }
        case "snapshot":
            try args.require(words: 0...0, flags: ["--json"], options: ["--dir"])
            if let directory = args.options["--dir"] {
                payload["dir"] = .string((directory as NSString).expandingTildeInPath)
            }
        case "updates":
            try args.require(words: 0...0, flags: ["--json"], options: ["--limit"])
            if let raw = args.options["--limit"] {
                guard let limit = Int64(raw), (1...200).contains(limit)
                else { throw HostCLIError.usage("--limit must be a positive integer up to 200.") }
                payload["limit"] = .integer(limit)
            }
        case "check-updates":
            try args.require(words: 0...0, flags: ["--json", "--no-wait"])
            payload["noWait"] = .bool(args.flags.contains("--no-wait"))
        case "reveal":
            try args.require(words: 0...1, flags: ["--json", "--list"], options: ["--tab"])
            guard !args.flags.contains("--list") || (args.words.isEmpty && args.options.isEmpty),
                args.options["--tab"] == nil || !args.words.isEmpty
            else {
                throw HostCLIError.usage(
                    "--list does not take a section; --tab requires a section.")
            }
            if let section = args.words.first { payload["section"] = .string(section) }
            if let tab = args.options["--tab"] { payload["tab"] = .string(tab) }
            payload["list"] = .bool(args.flags.contains("--list"))
        case "quit", "relaunch", "clear-updates":
            try args.require(words: 0...0, flags: ["--json", "--yes"])
            if !args.flags.contains("--yes") {
                let preview: HostCLIJSON = .object([
                    "action": .string(action), "targets": .strings(["this Edith installation"]),
                    "applied": .bool(false), "changed": .bool(false),
                    "requiresConfirmation": .bool(true),
                ])
                return json
                    ? try HostCLIOutput.json(preview)
                    : try HostCLIOutput.text(
                        "would \(action) this Edith installation; pass --yes to apply")
            }
        default: try args.require(words: 0...0, flags: ["--json"])
        }
        try Task.checkCancellation()
        var value = try await perform(action, payload)
        try Task.checkCancellation()
        if Self.destructive.contains(action), var object = value.object {
            object["applied"] = .bool(true)
            value = .object(object)
        }
        if json { return try HostCLIOutput.json(value) }
        if ["route", "navigate", "back", "forward"].contains(action),
            let route = value.object?["route"]?.string
        {
            return try HostCLIOutput.text(route)
        }
        if action == "snapshot", let files = value.object?["files"]?.array {
            return try HostCLIOutput.text(files.compactMap(\.string).joined(separator: "\n"))
        }
        if let string = value.string { return try HostCLIOutput.text(string) }
        if ["open", "quit", "test-notification"].contains(action) {
            return try HostCLIOutput.text(action + " requested")
        }
        return try HostCLIOutput.text(HostCLIOutput.text(value))
    }

    public static let actions = [
        "info", "diagnostics", "paths", "links", "open-path", "open-link", "clean-keys",
        "test-notification", "open", "quit", "check-updates", "updates", "relaunch",
        "clear-updates", "reveal", "route", "navigate", "back", "forward", "snapshot",
    ]
    private static let destructive: Set<String> = ["quit", "relaunch", "clear-updates"]
    private static let oneShotActions = [
        ("clean-keys", "Lock the keyboard for cleaning.", "menuBar"),
        ("test-notification", "Send a test notification.", "menuBar"),
        ("open", "Open the Edith panel.", "menuBar"),
        ("quit", "Quit the Edith main app.", "mainApp"),
        ("check-updates", "Check for an Edith update.", "mainApp"),
        ("reveal", "Reveal an Edith section.", "mainApp"),
        ("snapshot", "Capture Edith windows as images.", "mainApp"),
    ]
}
