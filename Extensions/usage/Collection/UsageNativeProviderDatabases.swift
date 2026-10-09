import Foundation

enum UsageNativeProviderDatabases {
    static func collect(home: URL, environment: [String: String], archive: UsageNativeArchive)
        throws
    {
        func roots(_ key: String, defaults: [String]) -> [URL] {
            if let value = environment[key] {
                return value.split(separator: ",").map {
                    URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespaces))
                }
            }
            return defaults.map { home.appendingPathComponent($0) }
        }
        var candidates: [(String, URL)] = []
        candidates += roots("HERMES_HOME", defaults: [".hermes"]).map {
            ("hermes", $0.appendingPathComponent("state.db"))
        }
        let gooseRoots =
            environment["GOOSE_PATH_ROOT"].map {
                [URL(fileURLWithPath: $0).appendingPathComponent("data/sessions")]
            }
            ?? roots(
                "GOOSE_DATA_DIR",
                defaults: [
                    ".local/share/goose/sessions", "Library/Application Support/goose/sessions",
                    ".local/share/Block/goose/sessions",
                ])
        candidates += gooseRoots.map { ("goose", $0.appendingPathComponent("sessions.db")) }
        candidates += roots("KILO_DATA_DIR", defaults: [".local/share/kilo"]).map {
            ("kilo", $0.appendingPathComponent("kilo.db"))
        }
        for root in roots(
            "OPENCLAW_DIR", defaults: [".openclaw", ".clawdbot", ".moltbot", ".moldbot"])
        {
            candidates += try UsageNativeFileIO.files(under: root, extensions: ["sqlite", "db"])
                .filter {
                    $0.lastPathComponent == "openclaw-agent.sqlite"
                }.map { ("openclaw", $0) }
        }
        var seen: Set<String> = []
        for (source, path) in candidates {
            try Task.checkCancellation()
            guard FileManager.default.fileExists(atPath: path.path), seen.insert(path.path).inserted
            else { continue }
            let database = try UsageNativeDatabase(url: path, readOnly: true)
            defer { database.close() }
            let events: [UsageNativeEvent]
            switch source {
            case "hermes": events = try hermes(database)
            case "goose": events = try goose(database)
            case "kilo": events = try kilo(database)
            default: events = try openClaw(database)
            }
            try archive.admitRemote(events, key: source + "-db:" + UsageNativeJSON.hash(path.path))
        }
    }

    private static func columns(_ database: UsageNativeDatabase, table: String) throws -> Set<
        String
    > {
        Set(try database.rows("PRAGMA table_info(" + table + ")").compactMap { $0["name"] })
    }

    private static func hermes(_ database: UsageNativeDatabase) throws -> [UsageNativeEvent] {
        let fields = try columns(database, table: "sessions")
        guard fields.contains("id"), fields.contains("model"), fields.contains("started_at") else {
            return []
        }
        func value(_ field: String, fallback: String = "0") -> String {
            fields.contains(field) ? field : fallback
        }
        let sql = """
            SELECT json_object('id',id,'model',model,'timestamp',started_at,
                'cwd',\(value("cwd", fallback: "''")),'title',\(value("title", fallback: "''")),
                'input',\(value("input_tokens")),'output',\(value("output_tokens")),
                'read',\(value("cache_read_tokens")),'creation',\(value("cache_write_tokens")),
                'reasoning',\(value("reasoning_tokens")),
                'cost',coalesce(\(value("actual_cost_usd", fallback: "NULL")),\(value("estimated_cost_usd", fallback: "NULL")))) AS payload
            FROM sessions WHERE model IS NOT NULL AND trim(model)!=''
            """
        return try payloads(database, sql: sql).compactMap { row in
            guard let session = UsageNativeJSON.text(row["id"]),
                let timestamp = UsageNativeJSON.date(row["timestamp"]),
                let model = UsageNativeJSON.text(row["model"])
            else { return nil }
            let tokens = try UsageNativeTokens(
                input: UsageNativeTokens.number(row["input"]),
                output: UsageNativeTokens.number(row["output"])
                    + UsageNativeTokens.number(row["reasoning"]),
                creation: UsageNativeTokens.number(row["creation"]),
                read: UsageNativeTokens.number(row["read"]))
            let cost = try UsageNativeTokens.amount(row["cost"])
            guard tokens.total > 0 || (cost ?? 0) > 0 else { return nil }
            return .init(
                source: "hermes", identity: session, session: session, model: model,
                timestamp: timestamp,
                cwd: UsageNativeJSON.text(row["cwd"]) ?? "",
                title: UsageNativeJSON.title(row["title"]), tokens: tokens, recordedCost: cost)
        }
    }

    private static func goose(_ database: UsageNativeDatabase) throws -> [UsageNativeEvent] {
        let fields = try columns(database, table: "sessions")
        guard fields.contains("id"), fields.contains("model_config_json"),
            fields.contains("created_at")
        else { return [] }
        func value(_ field: String) -> String { fields.contains(field) ? field : "0" }
        func cumulative(_ field: String) -> String {
            let base = value(field)
            guard fields.contains("accumulated_" + field) else { return base }
            return "coalesce(nullif(accumulated_" + field + ",0)," + base + ",0)"
        }
        let sql = """
            SELECT json_object('id',id,'model',json_extract(model_config_json,'$.model_name'),'timestamp',created_at,
                'input',\(cumulative("input_tokens")),'output',\(cumulative("output_tokens")),'total',\(cumulative("total_tokens"))) AS payload
            FROM sessions WHERE model_config_json IS NOT NULL AND trim(model_config_json)!=''
            """
        return try payloads(database, sql: sql).compactMap { row in
            guard let session = UsageNativeJSON.text(row["id"]),
                let model = UsageNativeJSON.text(row["model"])
            else { return nil }
            var raw = row["timestamp"]
            if let text = raw as? String, text.count == 19, text.contains(" ") {
                raw = text.replacingOccurrences(of: " ", with: "T") + "Z"
            }
            guard let timestamp = UsageNativeJSON.date(raw) else { return nil }
            let input = try UsageNativeTokens.number(row["input"])
            let output = try UsageNativeTokens.number(row["output"])
            let total = try UsageNativeTokens.number(row["total"])
            let tokens = UsageNativeTokens(input: input, output: max(output, total - input))
            guard tokens.total > 0 else { return nil }
            return .init(
                source: "goose", identity: session, session: session, model: model,
                timestamp: timestamp,
                cwd: "", title: nil, tokens: tokens, recordedCost: nil)
        }
    }

    private static func kilo(_ database: UsageNativeDatabase) throws -> [UsageNativeEvent] {
        let fields = try columns(database, table: "message")
        guard fields.contains("id"), fields.contains("session_id"), fields.contains("data") else {
            return []
        }
        let sql = """
            SELECT json_object('id',id,'sessionID',session_id,'role','assistant',
                'modelID',json_extract(data,'$.modelID'),'time',json(json_extract(data,'$.time')),
                'tokens',json(json_extract(data,'$.tokens')),'cost',json_extract(data,'$.cost')) AS payload
            FROM message WHERE json_extract(data,'$.role')='assistant'
            """
        let parser = UsageNativeParser(source: "kilo")
        return try payloads(database, sql: sql).flatMap {
            try parser.openCode($0).map { [$0] } ?? []
        }
    }

    private static func openClaw(_ database: UsageNativeDatabase) throws -> [UsageNativeEvent] {
        let fields = try columns(database, table: "transcript_events")
        guard fields.contains("session_id"), fields.contains("event_json") else { return [] }
        let sql = """
            SELECT json_object('id',json_extract(event_json,'$.id'),'type','message','sessionId',session_id,
                'timestamp',coalesce(json_extract(event_json,'$.timestamp'),json_extract(event_json,'$.message.timestamp')),
                'message',json_object('role','assistant','model',coalesce(json_extract(event_json,'$.message.model'),json_extract(event_json,'$.message.modelId')),
                    'usage',json(json_extract(event_json,'$.message.usage')))) AS payload
            FROM transcript_events WHERE json_extract(event_json,'$.message.role')='assistant'
            """
        let parser = UsageNativeParser(source: "openclaw")
        return try payloads(database, sql: sql).flatMap { try parser.consume($0).map(\.event) }
    }

    private static func payloads(_ database: UsageNativeDatabase, sql: String) throws -> [[String:
        Any]]
    {
        try database.rows(sql).map { row in
            try Task.checkCancellation()
            guard let text = row["payload"], text.utf8.count <= 1_048_576 else {
                throw UsageNativeFailure.capacity
            }
            return try UsageNativeJSON.object(Data(text.utf8))
        }
    }
}
