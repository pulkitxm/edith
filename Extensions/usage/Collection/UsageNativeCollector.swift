import Darwin
import Foundation

public enum UsageNativeCollector {
    public static func collect(
        home: URL, dataDirectory: URL, environment: [String: String],
        now: Date = Date(), onEvent: @escaping @Sendable (UsageRefreshEvent) -> Void
    ) async throws -> Data {
        try await collect(
            home: home, dataDirectory: dataDirectory, environment: environment, now: now,
            network: UsageNativeNetwork(), onEvent: onEvent)
    }

    static func collect(
        home: URL, dataDirectory: URL, environment: [String: String], now: Date,
        network: UsageNativeNetwork, onEvent: @escaping @Sendable (UsageRefreshEvent) -> Void
    ) async throws -> Data {
        let started = ContinuousClock.now
        try Task.checkCancellation()
        let archive = try UsageNativeArchive(dataDirectory: dataDirectory)
        let previous = try UsageNativeFileIO.optionalObject(
            dataDirectory.appendingPathComponent("usage.json"))
        try archive.bootstrap(previous?.objectSchema8)
        let roots = try discover(home: home, environment: environment)
        var seen: Set<String> = []
        var scanned = 0
        var timestamp = ContinuousClock.now
        for root in roots {
            let files = try UsageNativeFileIO.files(
                under: root.path, extensions: ["jsonl", "json"])
            for file in files {
                try Task.checkCancellation()
                if root.source == "opencode", !file.path.contains("/message/") { continue }
                if root.source == "grok", file.lastPathComponent != "updates.jsonl" { continue }
                if root.source == "droid", !file.lastPathComponent.hasSuffix(".settings.json") {
                    continue
                }
                if root.source == "codebuff", file.lastPathComponent != "chat-messages.json" {
                    continue
                }
                if root.source == "kimi", file.lastPathComponent != "wire.jsonl" { continue }
                let key = root.source + ":" + UsageNativeJSON.hash(file.path)
                guard seen.insert(key).inserted else { continue }
                let previous = try archive.known(key)
                var status = stat()
                guard lstat(file.path, &status) == 0 else { continue }
                let modified =
                    Double(status.st_mtimespec.tv_sec) + Double(status.st_mtimespec.tv_nsec) / 1e9
                if let previous, previous.size == Int(status.st_size), previous.modified == modified
                {
                    continue
                }
                if file.pathExtension.lowercased() == "json" {
                    let data = try UsageNativeFileIO.read(file)
                    let object = try JSONSerialization.jsonObject(with: data)
                    let parser = UsageNativeParser(source: root.source)
                    let records = try parser.document(object, path: file, modified: modified)
                    let prefix =
                        previous.map { UsageNativeJSON.hash(Data(data.prefix($0.size))) }
                        ?? UsageNativeJSON.hash(Data())
                    try archive.admit(
                        .init(
                            path: key, size: data.count, completeBytes: data.count,
                            modified: modified,
                            hash: UsageNativeJSON.hash(data), prefixHash: prefix, records: records),
                        previous: previous)
                } else {
                    let parser = UsageNativeParser(source: root.source, tier: root.tier)
                    let snapshot = try parser.snapshot(file, key: key, previous: previous)
                    try archive.admit(snapshot, previous: previous)
                }
                scanned += 1
            }
            onEvent(
                .phase(
                    name: root.source, detail: "Local receipts scanned",
                    seconds: elapsed(since: timestamp)))
            timestamp = .now
        }
        try collectOpenCodeDatabases(home: home, environment: environment, archive: archive)
        try UsageNativeProviderDatabases.collect(
            home: home, environment: environment, archive: archive)
        let candidates = try archive.unresolvedCandidates()
        let retained = try archive.retainedFiles(seen: seen)
        if candidates > 0 {
            onEvent(
                .note("\(candidates) rewritten receipts need reconciliation and remain uncounted"))
        }
        if retained > 0 { onEvent(.note("Usage retained from \(retained) missing journals")) }
        var cloud: [String] = []
        if environment["EDITH_USAGE_OFFLINE"] != "1" {
            cloud = try await UsageNativeCloud.collect(
                home: home, environment: environment, now: now,
                archive: archive, network: network, onEvent: onEvent)
        }
        try Task.checkCancellation()
        let zone = environment["TZ"].flatMap(TimeZone.init(identifier:)) ?? .current
        let document = try UsageNativeAssembly.document(
            events: archive.events(), archive: archive, now: now,
            timezone: zone, cloudSources: cloud)
        let unpriced = (document["pricing"] as? [String: Any])?["unpricedModels"] as? [String] ?? []
        if !unpriced.isEmpty {
            onEvent(
                .note(
                    "Cost estimates are unavailable for \(unpriced.count) model(s); token counts are retained"
                ))
        }
        let data = try UsageNativeJSON.encode(document)
        guard data.count <= 67_108_864 else { throw UsageNativeFailure.capacity }
        onEvent(.summary(label: "journals", value: String(scanned)))
        onEvent(.summary(label: "days", value: String((document["daily"] as? [Any])?.count ?? 0)))
        onEvent(.finished(seconds: elapsed(since: started)))
        try Task.checkCancellation()
        return data
    }

    struct Root {
        let source: String
        let path: URL
        var tier: String? = nil
    }

    static func discover(home: URL, environment: [String: String]) throws -> [Root] {
        var roots: [Root] = []
        func configured(_ key: String, fallback: String) -> [URL] {
            let value = environment[key] ?? home.appendingPathComponent(fallback).path
            return value.split(separator: ",").map {
                URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespaces))
            }
        }
        for root in configured("CLAUDE_CONFIG_DIR", fallback: ".claude") {
            roots.append(.init(source: "cli", path: root.appendingPathComponent("projects")))
        }
        let cowork = home.appendingPathComponent(
            "Library/Application Support/Claude/local-agent-mode-sessions")
        if let iterator = FileManager.default.enumerator(
            at: cowork, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        {
            var inspected = 0
            for case let path as URL in iterator {
                try Task.checkCancellation(); inspected += 1
                guard inspected <= 100_000 else { throw UsageNativeFailure.capacity }
                var metadata = stat()
                guard lstat(path.path, &metadata) == 0 else { continue }
                if metadata.st_mode & S_IFMT == S_IFLNK { iterator.skipDescendants(); continue }
                if path.lastPathComponent == ".claude", metadata.st_mode & S_IFMT == S_IFDIR {
                    roots.append(
                        .init(source: "cowork", path: path.appendingPathComponent("projects")))
                    iterator.skipDescendants()
                }
            }
        }
        for root in configured("CODEX_HOME", fallback: ".codex") {
            let candidates = [
                root.appendingPathComponent("sessions"),
                root.appendingPathComponent("archived_sessions"),
            ]
            let existing = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
            let config = try? String(
                decoding: UsageNativeFileIO.read(
                    root.appendingPathComponent("config.toml"), maximum: 1_048_576), as: UTF8.self)
            let tier = config.flatMap { text in
                text.split(separator: "\n").first(where: {
                    $0.trimmingCharacters(in: .whitespaces).hasPrefix("service_tier")
                })
                .flatMap {
                    $0.split(separator: "=", maxSplits: 1).last.map {
                        $0.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                    }
                }
            }
            for path in existing.isEmpty ? [root] : existing {
                roots.append(.init(source: "codex", path: path, tier: tier))
            }
        }
        let xdg =
            environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".local/share")
        for root in configured("OPENCODE_DATA_DIR", fallback: ".local/share/opencode") {
            roots.append(
                .init(source: "opencode", path: root.appendingPathComponent("storage/message")))
        }
        roots.append(
            .init(source: "opencode", path: xdg.appendingPathComponent("opencode/storage/message")))
        roots.append(.init(source: "cursor", path: home.appendingPathComponent(".cursor/chats")))
        let additional: [(String, String, String)] = [
            ("pi", "PI_CODING_AGENT_DIR", ".pi/agent/sessions"),
            ("commandcode", "COMMAND_CODE_HOME", ".commandcode/projects"),
            ("amp", "AMP_DATA_DIR", ".local/share/amp"),
            ("droid", "DROID_SESSIONS_DIR", ".factory/sessions"),
            ("codebuff", "CODEBUFF_DATA_DIR", ".config/manicode/projects"),
            ("hermes", "HERMES_HOME", ".hermes/sessions"),
            ("goose", "GOOSE_DATA_DIR", ".local/share/goose/sessions"),
            ("kilo", "KILO_DATA_DIR", ".local/share/kilo"),
            ("gemini", "GEMINI_DATA_DIR", ".gemini/tmp"),
            ("copilot", "COPILOT_HOME", ".copilot"),
            ("kimi", "KIMI_DATA_DIR", ".kimi/sessions"),
            ("qwen", "QWEN_DATA_DIR", ".qwen/projects"),
            ("openclaw", "OPENCLAW_DIR", ".openclaw"),
            ("grok", "GROK_HOME", ".grok/sessions"),
        ]
        for (source, key, fallback) in additional {
            for path in configured(key, fallback: fallback) {
                let suffix = [
                    "pi": "sessions", "commandcode": "projects", "grok": "sessions",
                    "hermes": "sessions", "kimi": "sessions", "qwen": "projects",
                    "codebuff": "projects",
                ][source]
                let path =
                    environment[key] != nil && suffix != nil
                    ? path.appendingPathComponent(suffix!) : path
                roots.append(.init(source: source, path: path))
            }
        }
        if environment["CODEBUFF_DATA_DIR"] == nil {
            for channel in ["manicode-dev", "manicode-staging"] {
                roots.append(
                    .init(
                        source: "codebuff",
                        path: home.appendingPathComponent(".config/" + channel + "/projects")))
            }
        }
        if environment["KIMI_DATA_DIR"] == nil {
            roots.append(
                .init(source: "kimi", path: home.appendingPathComponent(".kimi-code/sessions")))
        }
        if environment["OPENCLAW_DIR"] == nil {
            for alias in [".clawdbot", ".moltbot", ".moldbot"] {
                roots.append(.init(source: "openclaw", path: home.appendingPathComponent(alias)))
            }
        }
        if let path = environment["COPILOT_OTEL_FILE_EXPORTER_PATH"] {
            roots.append(.init(source: "copilot", path: URL(fileURLWithPath: path)))
        }
        return roots
    }

    private static func collectOpenCodeDatabases(
        home: URL, environment: [String: String], archive: UsageNativeArchive
    ) throws {
        let base =
            environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".local/share")
        let root =
            environment["OPENCODE_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? base.appendingPathComponent("opencode")
        let file = root.appendingPathComponent("opencode.db")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let database = try UsageNativeDatabase(url: file, readOnly: true)
        defer { database.close() }
        let tables = Set(
            try database.rows("SELECT name FROM sqlite_master WHERE type='table'").compactMap {
                $0["name"]
            })
        let schemas: [(String, String, String)] = [
            ("message", "session", "json_extract(m.data,'$.role')='assistant'"),
            ("session_message", "session_v2", "m.type='assistant'"),
        ]
        var events: [UsageNativeEvent] = []
        for (messages, sessions, predicate) in schemas where tables.contains(messages) {
            let session =
                tables.contains(sessions) ? "LEFT JOIN \(sessions) s ON s.id=m.session_id" : ""
            let directory = tables.contains(sessions) ? "s.directory" : "''"
            let title = tables.contains(sessions) ? "s.title" : "''"
            let fallbackTime = messages == "session_message" ? "m.time_created" : "NULL"
            let sql = """
                SELECT json_object('id',m.id,'sessionID',m.session_id,'role','assistant',
                  'modelID',coalesce(json_extract(m.data,'$.modelID'),json_extract(m.data,'$.model.id'),'unknown'),
                  'time',json_object('created',coalesce(json_extract(m.data,'$.time.created'),\(fallbackTime))),
                  'path',json_object('cwd',coalesce(nullif(json_extract(m.data,'$.path.cwd'),''),\(directory),'')),
                  'title',\(title),'cost',json_extract(m.data,'$.cost'),'tokens',json(json_extract(m.data,'$.tokens'))) AS payload
                FROM \(messages) m \(session) WHERE \(predicate)
                """
            let parser = UsageNativeParser(source: "opencode")
            for row in try database.rows(sql) {
                guard let payload = row["payload"], payload.utf8.count <= 1_048_576 else {
                    throw UsageNativeFailure.capacity
                }
                events.append(
                    contentsOf: try parser.consume(UsageNativeJSON.object(Data(payload.utf8))).map(
                        \.event))
            }
        }
        try archive.admitRemote(events, key: "opencode-db:" + UsageNativeJSON.hash(file.path))
    }

    private static func elapsed(since start: ContinuousClock.Instant) -> Double {
        let parts = start.duration(to: .now).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

private extension Dictionary where Key == String, Value == Any {
    var objectSchema8: [String: Any]? { self["schemaVersion"] as? Int == 8 ? self : nil }
}
