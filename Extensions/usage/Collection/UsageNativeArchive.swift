import Foundation

final class UsageNativeArchive {
    struct KnownFile {
        let size: Int
        let completeBytes: Int
        let modified: Double
        let hash: String
        let generation: Int
    }

    let database: UsageNativeDatabase
    private let limits: UsageNativeFileLimits

    init(dataDirectory: URL, limits: UsageNativeFileLimits = .init()) throws {
        self.limits = limits
        let root = dataDirectory.appendingPathComponent("native-usage-history", isDirectory: true)
        try UsageNativeFileIO.privateDirectory(root)
        database = try UsageNativeDatabase(url: root.appendingPathComponent("usage.sqlite"))
        let version = try database.rows("PRAGMA user_version").first?["user_version"] ?? "0"
        guard version == "0" || version == "1" else {
            throw UsageNativeFailure.archive("open an unsupported schema")
        }
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY,size INTEGER NOT NULL,
              complete_bytes INTEGER NOT NULL,mtime REAL NOT NULL,hash TEXT NOT NULL,generation INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS records(sequence INTEGER PRIMARY KEY,path TEXT NOT NULL,
              identity TEXT NOT NULL,hash TEXT NOT NULL,payload TEXT NOT NULL,UNIQUE(path,identity,hash));
            CREATE INDEX IF NOT EXISTS records_path ON records(path,sequence);
            CREATE TABLE IF NOT EXISTS candidates(path TEXT NOT NULL,identity TEXT NOT NULL,hash TEXT NOT NULL,
              payload TEXT NOT NULL,PRIMARY KEY(path,identity,hash));
            CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS baselines(period TEXT PRIMARY KEY,payload TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS aggregate_candidates(period TEXT NOT NULL,hash TEXT NOT NULL,payload TEXT NOT NULL,
              PRIMARY KEY(period,hash));
            CREATE TABLE IF NOT EXISTS cloud_cache(key TEXT PRIMARY KEY,payload TEXT NOT NULL);
            PRAGMA user_version=1;
            """)
        let payloadTables = ["records", "candidates", "baselines", "aggregate_candidates", "cloud_cache"]
        let byteCount = payloadTables.map { "COALESCE((SELECT SUM(length(CAST(payload AS BLOB))) FROM " + $0 + "),0)" }.joined(separator: "+")
        try database.execute("""
            CREATE TABLE IF NOT EXISTS capacity(singleton INTEGER PRIMARY KEY CHECK(singleton=1),files INTEGER NOT NULL,records INTEGER NOT NULL,bytes INTEGER NOT NULL);
            INSERT INTO capacity SELECT 1,(SELECT COUNT(*) FROM files),
                (SELECT COUNT(*) FROM records)+(SELECT COUNT(*) FROM candidates),\(byteCount)
                WHERE NOT EXISTS(SELECT 1 FROM capacity);
            CREATE TRIGGER IF NOT EXISTS capacity_files_insert AFTER INSERT ON files BEGIN UPDATE capacity SET files=files+1; END;
            CREATE TRIGGER IF NOT EXISTS capacity_files_delete AFTER DELETE ON files BEGIN UPDATE capacity SET files=files-1; END;
            """)
        for table in payloadTables {
            let insertCount = ["records", "candidates"].contains(table) ? ",records=records+1" : ""
            let deleteCount = ["records", "candidates"].contains(table) ? ",records=records-1" : ""
            try database.execute("""
                CREATE TRIGGER IF NOT EXISTS capacity_\(table)_insert AFTER INSERT ON \(table) BEGIN
                    UPDATE capacity SET bytes=bytes+length(CAST(new.payload AS BLOB))\(insertCount); END;
                CREATE TRIGGER IF NOT EXISTS capacity_\(table)_delete AFTER DELETE ON \(table) BEGIN
                    UPDATE capacity SET bytes=bytes-length(CAST(old.payload AS BLOB))\(deleteCount); END;
                CREATE TRIGGER IF NOT EXISTS capacity_\(table)_update AFTER UPDATE OF payload ON \(table) BEGIN
                    UPDATE capacity SET bytes=bytes+length(CAST(new.payload AS BLOB))-length(CAST(old.payload AS BLOB)); END;
                """)
        }

    }

    func known(_ path: String) throws -> KnownFile? {
        guard
            let row = try database.rows("SELECT * FROM files WHERE path=?", [path], maximum: 1)
                .first,
            let size = Int(row["size"] ?? ""), let complete = Int(row["complete_bytes"] ?? ""),
            let modified = Double(row["mtime"] ?? ""), let hash = row["hash"],
            let generation = Int(row["generation"] ?? "")
        else { return nil }
        return .init(
            size: size, completeBytes: complete, modified: modified, hash: hash,
            generation: generation)
    }

    func admit(_ snapshot: UsageNativeFileSnapshot, previous: KnownFile?) throws {
        let appended =
            previous == nil
            || (snapshot.size >= previous!.size && snapshot.prefixHash == previous!.hash)
        try database.transaction {
            let latest = try known(snapshot.path)
            guard latest?.hash == previous?.hash, latest?.generation == previous?.generation else {
                throw UsageNativeFailure.archive("admit a concurrently changed source")
            }
            if snapshot.records.contains(where: { $0.event.source == "codex" && $0.event.receiptID != nil }) {
                try database.run("DELETE FROM records WHERE path=? AND identity LIKE 'legacy:%'", [snapshot.path])
            }
            let generation = (previous?.generation ?? 0) + (previous != nil && !appended ? 1 : 0)
            for record in snapshot.records {
                try Task.checkCancellation()
                if appended, let previous, record.offset < previous.completeBytes { continue }
                let payload = String(decoding: try record.event.canonicalData, as: UTF8.self)
                let hash = UsageNativeJSON.hash(payload)
                if previous != nil, !appended, record.event.identity == nil {
                    try database.run(
                        "INSERT OR IGNORE INTO candidates VALUES(?,?,?,?)",
                        [snapshot.path, snapshot.hash + ":" + String(record.offset), hash, payload])
                } else {
                    try database.run(
                        "INSERT OR IGNORE INTO records(path,identity,hash,payload) VALUES(?,?,?,?)",
                        [
                            snapshot.path,
                            record.event.identity ?? String(generation) + ":"
                                + String(record.offset), hash, payload,
                        ])
                }
            }
            try database.run(
                """
                INSERT INTO files VALUES(?,?,?,?,?,?) ON CONFLICT(path) DO UPDATE SET
                size=excluded.size,complete_bytes=excluded.complete_bytes,mtime=excluded.mtime,
                hash=excluded.hash,generation=excluded.generation
                """,
                [
                    snapshot.path, snapshot.size, snapshot.completeBytes, snapshot.modified,
                    snapshot.hash, generation,
                ])
            try enforceCapacity()
        }
    }

    func admitRemote(_ events: [UsageNativeEvent], key: String) throws {
        try database.transaction {
            for (index, event) in events.enumerated() {
                try Task.checkCancellation()
                let payload = String(decoding: try event.canonicalData, as: UTF8.self)
                try database.run(
                    "INSERT OR IGNORE INTO records(path,identity,hash,payload) VALUES(?,?,?,?)",
                    [key, event.identity ?? String(index), UsageNativeJSON.hash(payload), payload])
            }
            try enforceCapacity()
        }
    }

    func replaceRemote(_ events: [UsageNativeEvent], key: String, account: String) throws {
        try database.transaction {
            try database.run("DELETE FROM records WHERE path=?", [key])
            try database.run(
                "INSERT INTO metadata VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                ["account:" + key, account])
            try insertRemote(events, key: key)
            try enforceCapacity()
        }
    }

    func retainRemote(_ events: [UsageNativeEvent], key: String, account: String) throws {
        try database.transaction {
            let previous = try database.rows("SELECT value FROM metadata WHERE key=?", ["account:" + key]).first?["value"]
            if previous != nil, previous != account {
                try database.run("DELETE FROM records WHERE path=?", [key])
            }
            try database.run(
                "INSERT INTO metadata VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                ["account:" + key, account])
            try insertRemote(events, key: key)
            try enforceCapacity()
        }
    }

    private func insertRemote(_ events: [UsageNativeEvent], key: String) throws {
        for (index, event) in events.enumerated() {
            try Task.checkCancellation()
            let payload = String(decoding: try event.canonicalData, as: UTF8.self)
            try database.run(
                "INSERT OR IGNORE INTO records(path,identity,hash,payload) VALUES(?,?,?,?)",
                [key, event.identity ?? String(index), UsageNativeJSON.hash(payload), payload])
        }
    }

    func events() throws -> [UsageNativeEvent] {
        var result: [UsageNativeEvent] = []
        for row in try database.rows(
            "SELECT path,identity,payload FROM records ORDER BY sequence", maximum: limits.records)
        {
            try Task.checkCancellation()
            guard let payload = row["payload"], payload.utf8.count <= limits.lineBytes else {
                throw UsageNativeFailure.archive("decode a record")
            }
            var event = try JSONDecoder().decode(UsageNativeEvent.self, from: Data(payload.utf8))
            if event.identity == nil {
                event.identity =
                    "anonymous:" + UsageNativeJSON.hash(row["path"] ?? "") + ":"
                    + (row["identity"] ?? "") + ":" + UsageNativeJSON.hash(payload)
            }
            result.append(event)
        }
        return result
    }

    func unresolvedCandidates() throws -> Int {
        Int(try database.rows("SELECT COUNT(*) AS count FROM candidates").first?["count"] ?? "0")
            ?? 0
    }

    func retainedFiles(seen: Set<String>) throws -> Int {
        try database.rows("SELECT path FROM files", maximum: limits.files).filter {
            !seen.contains($0["path"] ?? "")
        }.count
    }

    func bootstrap(_ previous: [String: Any]?) throws {
        if try database.rows("SELECT value FROM metadata WHERE key='baseline'").first != nil {
            return
        }
        let generated = previous?["generatedAt"] as? String ?? ""
        let blocks = (previous?["daily"] as? [[String: Any]] ?? []).compactMap {
            day -> [String: Any]? in
            let sources = day["bySource"] as? [String: Any] ?? [:]
            guard let cli = sources["cli"], let period = day["period"] as? String else {
                return nil
            }
            let hours = (day["hours"] as? [[String: Any]] ?? []).map {
                Self.cliDetail($0, paths: true)
            }
            let projects = (day["projects"] as? [[String: Any]] ?? []).compactMap {
                project -> [String: Any]? in
                guard (project["bySource"] as? [String: Any])?["cli"] != nil else { return nil }
                var project = Self.cliDetail(project, paths: false)
                project["chats"] = (project["chats"] as? [[String: Any]] ?? []).filter {
                    $0["source"] as? String == "cli"
                }
                project["worktrees"] = (project["worktrees"] as? [[String: Any]] ?? []).compactMap {
                    worktree -> [String: Any]? in
                    let chats = (worktree["chats"] as? [[String: Any]] ?? []).filter {
                        $0["source"] as? String == "cli"
                    }
                    guard !chats.isEmpty else { return nil }
                    return [
                        "name": worktree["name"] ?? "", "chats": chats,
                        "tokens": chats.reduce(0.0) { $0 + ($1["tokens"] as? Double ?? 0) },
                        "cost": chats.reduce(0.0) { $0 + ($1["cost"] as? Double ?? 0) },
                    ]
                }
                return project
            }
            guard hours.count == 24 else { return nil }
            return [
                "period": period, "bySource": ["cli": cli], "hours": hours, "projects": projects,
            ]
        }
        guard blocks.count <= 4096 else { throw UsageNativeFailure.capacity }
        try database.transaction {
            for block in blocks {
                let payload = String(decoding: try UsageNativeJSON.encode(block), as: UTF8.self)
                try database.run(
                    "INSERT INTO baselines VALUES(?,?)", [block["period"] as! String, payload])
            }
            try database.run("INSERT INTO metadata VALUES('baseline',?)", [generated])
            try enforceCapacity()
        }
    }

    func reconcile(_ daily: [[String: Any]]) throws -> [String: Any] {
        let fresh = Dictionary(
            uniqueKeysWithValues: daily.compactMap { day -> (String, [String: Any])? in
                guard let period = day["period"] as? String else { return nil }
                return (period, day)
            })
        return try database.transaction {
            var blocks: [[String: Any]] = []
            let generated =
                try database.rows("SELECT value FROM metadata WHERE key='baseline'").first?["value"]
                ?? ""
            for baseline in try database.rows(
                "SELECT period,payload FROM baselines ORDER BY period", maximum: 4096)
            {
                guard let period = baseline["period"], let payload = baseline["payload"] else {
                    continue
                }
                let original = try UsageNativeJSON.object(Data(payload.utf8))
                var incoming =
                    fresh[period] ?? [
                        "period": period, "bySource": [:],
                        "hours": (0..<24).map { _ in
                            ["tokens": 0, "cost": 0, "bySource": [:], "byPath": [:]]
                                as [String: Any]
                        }, "projects": [],
                    ]
                let sources = incoming["bySource"] as? [String: Any] ?? [:]
                incoming["bySource"] = sources["cli"].map { ["cli": $0] } ?? [:]
                incoming["hours"] = (incoming["hours"] as? [[String: Any]] ?? []).map {
                    Self.cliDetail($0, paths: true)
                }
                incoming["projects"] = (incoming["projects"] as? [[String: Any]] ?? []).compactMap {
                    project -> [String: Any]? in
                    (project["bySource"] as? [String: Any])?["cli"] != nil
                        ? Self.cliDetail(project, paths: false) : nil
                }
                let encoded = try UsageNativeJSON.encode(incoming)
                if encoded != (try UsageNativeJSON.encode(original)) {
                    try database.run(
                        "INSERT OR IGNORE INTO aggregate_candidates VALUES(?,?,?)",
                        [
                            period, UsageNativeJSON.hash(encoded),
                            String(decoding: encoded, as: UTF8.self),
                        ])
                }
                let candidates = try database.rows(
                    "SELECT payload FROM aggregate_candidates WHERE period=? ORDER BY hash",
                    [period], maximum: 8192)
                guard !candidates.isEmpty else { continue }
                blocks.append([
                    "period": period, "source": "cli", "state": "partial-overlap",
                    "provenance": ["kind": "published-aggregate", "generatedAt": generated],
                    "baseline": original,
                    "candidates": try candidates.map {
                        try UsageNativeJSON.object(Data(($0["payload"] ?? "{}").utf8))
                    },
                ])
            }
            guard try UsageNativeJSON.encode(["blocks": blocks]).count <= 16_777_216 else {
                throw UsageNativeFailure.capacity
            }
            try enforceCapacity()
            return ["version": 1, "blocks": blocks]
        }
    }

    func cached(_ key: String) throws -> [String: Any]? {
        guard
            let payload = try database.rows(
                "SELECT payload FROM cloud_cache WHERE key=?", [key], maximum: 1
            ).first?["payload"]
        else { return nil }
        return try UsageNativeJSON.object(Data(payload.utf8))
    }

    func cache(_ value: [String: Any], key: String) throws {
        let data = try UsageNativeJSON.encode(value)
        guard data.count <= 33_554_432 else { throw UsageNativeFailure.capacity }
        try database.transaction {
            try database.run(
                "INSERT INTO cloud_cache VALUES(?,?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload",
                [key, String(decoding: data, as: UTF8.self)])
            try enforceCapacity()
        }
    }

    private func enforceCapacity() throws {
        let record = try database.rows("SELECT files,records,bytes FROM capacity WHERE singleton=1", maximum: 1).first ?? [:]
        guard (Int(record["files"] ?? "0") ?? .max) <= limits.files,
            (Int(record["records"] ?? "0") ?? .max) <= limits.records,
            (Int(record["bytes"] ?? "0") ?? .max) <= limits.bytes
        else { throw UsageNativeFailure.capacity }
    }

    private static func cliDetail(_ node: [String: Any], paths: Bool) -> [String: Any] {
        var result = node
        let source = (node["bySource"] as? [String: Any])?["cli"] as? [String: Any]
        result["bySource"] = source.map { ["cli": $0] } ?? [:]
        result["tokens"] = source?["tokens"] ?? 0
        result["cost"] = source?["cost"] ?? 0
        if paths {
            result["byPath"] = (node["byPath"] as? [String: [String: Any]] ?? [:]).compactMapValues
            {
                ($0["bySource"] as? [String: Any])?["cli"] != nil
                    ? cliDetail($0, paths: false) : nil
            }
        }
        return result
    }
}
