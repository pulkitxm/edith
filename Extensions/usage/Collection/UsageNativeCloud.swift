import Foundation
import Security
import LocalAuthentication

final class UsageNativeCloud {
    private static let clients: Set<String> = [
        "CODEX_WEB", "CODEX_CLOUD", "CODEX_WORK_WEB", "CODEX_WORK_MOBILE", "CODEX_GITHUB",
        "CODEX_GITHUB_CODE_REVIEW", "CODEX_SLACK", "CODEX_LINEAR",
    ]

    static func collect(
        home: URL, environment: [String: String], now: Date, archive: UsageNativeArchive,
        network: UsageNativeNetwork, onEvent: @escaping @Sendable (UsageRefreshEvent) -> Void
    ) async throws -> [String] {
        var sources: [String] = []
        let providers: [(String, () async throws -> Bool)] = [
            ("claude-cloud", { try await claude(home: home, environment: environment, archive: archive, network: network, onEvent: onEvent) }),
            ("codex-cloud", { try await codex(home: home, environment: environment, now: now, archive: archive, network: network) }),
            ("cursor", { try await cursor(home: home, environment: environment, now: now, archive: archive, network: network) }),
        ]
        for (source, collect) in providers {
            try Task.checkCancellation()
            do {
                if try await collect() { sources.append(source) }
            } catch {
                try Task.checkCancellation()
                onEvent(.note("\(source) refresh is unavailable; previously collected receipts are retained"))
            }
        }
        return sources
    }

    static func normalizeCodex(_ response: [String: Any]) throws -> [UsageNativeEvent] {
        guard response["group_by"] as? String == "day", let days = response["data"] as? [[String: Any]] else {
            throw UsageNativeFailure.invalidInput("cloud analytics")
        }
        var seenDays: Set<String> = []
        var result: [UsageNativeEvent] = []
        for day in days {
            guard let date = day["date"] as? String, let timestamp = cloudDay(date),
                seenDays.insert(date).inserted, let entries = day["clients"] as? [[String: Any]] else {
                throw UsageNativeFailure.invalidInput("cloud analytics day")
            }
            var seenClients: Set<String> = []
            for entry in entries {
                guard let client = entry["client_id"] as? String, clients.contains(client) else { continue }
                guard seenClients.insert(client).inserted,
                    entry["uncached_text_input_tokens"] != nil, entry["cached_text_input_tokens"] != nil,
                    entry["text_output_tokens"] != nil, entry["text_total_tokens"] != nil else {
                    throw UsageNativeFailure.invalidInput("cloud analytics client")
                }
                let tokens = try UsageNativeTokens(
                    input: UsageNativeTokens.number(entry["uncached_text_input_tokens"]),
                    output: UsageNativeTokens.number(entry["text_output_tokens"]),
                    read: UsageNativeTokens.number(entry["cached_text_input_tokens"]))
                guard tokens.total == (try UsageNativeTokens.number(entry["text_total_tokens"])) else {
                    throw UsageNativeFailure.invalidInput("cloud analytics total")
                }
                let cost: Double
                if let amount = try UsageNativeTokens.amount(entry["cost_usd"]) {
                    cost = amount
                } else {
                    guard response["balance_unit"] as? String == "credit",
                        let credits = try UsageNativeTokens.amount(entry["credits"]) else {
                        throw UsageNativeFailure.invalidInput("cloud analytics currency")
                    }
                    cost = credits * 0.04
                }
                guard tokens.total > 0 || cost > 0 else { continue }
                result.append(.init(
                    source: "codex-cloud", identity: date + ":" + client, session: "", model: "unattributed-cloud-model",
                    timestamp: timestamp, cwd: "", title: nil, tokens: tokens, recordedCost: cost, detailAvailable: false, reportingDay: date))
            }
        }
        return result
    }

    private static func codex(
        home: URL, environment: [String: String], now: Date, archive: UsageNativeArchive, network: UsageNativeNetwork
    ) async throws -> Bool {
        let root = configured("CODEX_HOME", fallback: ".codex", home: home, environment: environment)
        guard let auth = try UsageNativeFileIO.optionalObject(root.appendingPathComponent("auth.json")),
            let tokens = auth["tokens"] as? [String: Any], let token = UsageNativeJSON.text(tokens["access_token"], maximum: 32_768) else { return false }
        let account = UsageNativeJSON.text(tokens["account_id"]) ?? jwtSubject(token) ?? UsageNativeJSON.hash(token)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var start = cloudDay("2025-05-16")!
        let end = calendar.startOfDay(for: now)
        var events: [UsageNativeEvent] = []
        while start <= end {
            try Task.checkCancellation()
            let last = min(calendar.date(byAdding: .day, value: 29, to: start)!, end)
            let response = try await network.object(request(
                "https://chatgpt.com/backend-api/wham/analytics/daily-workspace-usage-counts", token: token,
                headers: ["ChatGPT-Account-Id": tokens["account_id"] as? String ?? ""],
                query: ["start_date": dayString(start), "end_date": dayString(last), "group_by": "day", "workspace_user": "true"]))
            let page = try normalizeCodex(response)
            guard page.allSatisfy({ $0.timestamp >= start && $0.timestamp <= last }) else {
                throw UsageNativeFailure.invalidInput("cloud analytics range")
            }
            events.append(contentsOf: page)
            guard events.count <= 100_000 else { throw UsageNativeFailure.capacity }
            start = calendar.date(byAdding: .day, value: 1, to: last)!
        }
        try archive.replaceRemote(events, key: "remote:codex-cloud", account: UsageNativeJSON.hash(account))
        return true
    }

    private static func claude(
        home: URL, environment: [String: String], archive: UsageNativeArchive, network: UsageNativeNetwork,
        onEvent: @escaping @Sendable (UsageRefreshEvent) -> Void
    ) async throws -> Bool {
        let root = configured("CLAUDE_CONFIG_DIR", fallback: ".claude", home: home, environment: environment)
        var credentials = try UsageNativeFileIO.optionalObject(root.appendingPathComponent(".credentials.json"))
        if credentials == nil, home.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL {
            let suffix = environment["CLAUDE_CONFIG_DIR"] == nil ? "" : "-" + String(UsageNativeJSON.hash(root.path.precomposedStringWithCanonicalMapping).prefix(8))
            let context = LAContext()
            context.interactionNotAllowed = true
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Claude Code-credentials" + suffix,
                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationContext as String: context,
            ]
            var found: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data,
                data.count <= 1_048_576 { credentials = try UsageNativeJSON.object(data) }
        }
        guard let oauth = credentials?["claudeAiOauth"] as? [String: Any],
            let token = UsageNativeJSON.text(oauth["accessToken"], maximum: 32_768) else { return false }
        if let scopes = oauth["scopes"] as? [String], !scopes.contains("user:sessions:claude_code") {
            throw UsageNativeFailure.invalidInput("cloud sign-in scope")
        }
        let config = try UsageNativeFileIO.optionalObject(home.appendingPathComponent(".claude.json"))
        let organization = environment["CLAUDE_CODE_ORGANIZATION_UUID"] ?? (config?["oauthAccount"] as? [String: Any])?["organizationUuid"] as? String ?? ""
        let cacheKey = "claude-receipts:" + UsageNativeJSON.hash(token + ":" + organization)
        let account = UsageNativeJSON.hash(organization.isEmpty ? jwtSubject(token) ?? token : organization)
        let cached = try archive.cached(cacheKey)
        let saved = cached?["version"] as? Int == 2 ? cached?["sessions"] as? [[String: Any]] : nil
        let headers = ["anthropic-version": "2023-06-01", "x-organization-uuid": organization]
        var records: [[String: Any]] = []
        do {
            var sessions: [[String: Any]] = []
            var seen: Set<String> = []
            var cursors: Set<String> = []
            var cursor: String?
            for page in 0..<100 {
                let response = try await network.object(request(
                    "https://api.anthropic.com/v1/code/sessions", token: token, headers: headers,
                    query: ["limit": "100", "cursor": cursor].compactMapValues { $0 }))
                guard let batch = response["data"] as? [[String: Any]] else {
                    throw UsageNativeFailure.invalidInput("cloud sessions")
                }
                for session in batch {
                    guard let id = session["id"] as? String, safeID(id) else {
                        throw UsageNativeFailure.invalidInput("cloud session identity")
                    }
                    if session["environment_kind"] as? String == "bridge" || !seen.insert(id).inserted { continue }
                    sessions.append(["id": id, "revision": session["last_event_at"] ?? NSNull()])
                    guard sessions.count <= 10_000 else { throw UsageNativeFailure.capacity }
                }
                cursor = try nextCursor(response, seen: &cursors)
                if cursor == nil { break }
                if page == 99 { throw UsageNativeFailure.capacity }
            }
            for session in sessions {
                try Task.checkCancellation()
                let id = session["id"] as! String
                let revision = session["revision"] as? String
                if let revision, let previous = saved?.first(where: { $0["id"] as? String == id && $0["revision"] as? String == revision }) {
                    _ = try decodeEvents(previous["events"])
                    records.append(previous)
                    continue
                }
                var events: [UsageNativeEvent] = []
                var cursors: Set<String> = []
                var cursor: String?
                let parser = UsageNativeParser(source: "claude-cloud")
                for page in 0..<100 {
                    let response = try await network.object(request(
                        "https://api.anthropic.com/v1/code/sessions/" + id + "/teleport-events", token: token, headers: headers,
                        query: ["limit": "1000", "cursor": cursor].compactMapValues { $0 }))
                    guard let batch = response["data"] as? [[String: Any]] else {
                        throw UsageNativeFailure.invalidInput("cloud session receipts")
                    }
                    for entry in batch {
                        var row = entry["payload"] as? [String: Any] ?? entry
                        if let data = row["data"] as? [String: Any], let message = data["message"] as? [String: Any] { row = message }
                        row["sessionId"] = id
                        guard let message = row["message"] as? [String: Any], message["usage"] != nil else { continue }
                        guard message["id"] as? String != nil, message["model"] as? String != nil,
                            UsageNativeJSON.date(row["timestamp"]) != nil else {
                            throw UsageNativeFailure.invalidInput("cloud receipt metadata")
                        }
                        let usage = message["usage"] as? [String: Any] ?? [:]
                        guard usage["input_tokens"] != nil, usage["output_tokens"] != nil else {
                            throw UsageNativeFailure.invalidInput("cloud receipt token count")
                        }
                        if let cache = usage["cache_creation"] as? [String: Any] {
                            let expected = try UsageNativeTokens.number(cache["ephemeral_5m_input_tokens"]) + UsageNativeTokens.number(cache["ephemeral_1h_input_tokens"])
                            guard expected == (try UsageNativeTokens.number(usage["cache_creation_input_tokens"])) else {
                                throw UsageNativeFailure.invalidInput("cloud receipt cache total")
                            }
                        }
                        events.append(contentsOf: try parser.consume(row).map(\.event))
                        guard events.count <= 100_000 else { throw UsageNativeFailure.capacity }
                    }
                    cursor = try nextCursor(response, seen: &cursors)
                    if cursor == nil { break }
                    if page == 99 { throw UsageNativeFailure.capacity }
                }
                let objects = try events.map { try JSONSerialization.jsonObject(with: $0.canonicalData) }
                records.append(["id": id, "revision": revision as Any? ?? NSNull(), "events": objects])
            }
            try archive.cache(["version": 2, "sessions": records], key: cacheKey)
        } catch {
            try Task.checkCancellation()
            guard let saved else { throw error }
            records = saved
            onEvent(.note("Cloud refresh unavailable. Using saved usage receipts."))
        }
        let events = try records.flatMap { record -> [UsageNativeEvent] in
            guard let id = record["id"] as? String, safeID(id) else {
                throw UsageNativeFailure.invalidInput("cloud cached session identity")
            }
            return try decodeEvents(record["events"])
        }
        try archive.retainRemote(events, key: "remote:claude-cloud", account: account)
        return true
    }

    private static func cursor(
        home: URL, environment: [String: String], now: Date, archive: UsageNativeArchive, network: UsageNativeNetwork
    ) async throws -> Bool {
        let config = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
        var auth: [String: Any]?
        for path in [config.appendingPathComponent("cursor/auth.json"), home.appendingPathComponent(".cursor/auth.json")] {
            if let value = try UsageNativeFileIO.optionalObject(path), value["accessToken"] as? String != nil { auth = value; break }
        }
        if auth == nil {
            let path = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            if FileManager.default.fileExists(atPath: path.path) {
                let database = try UsageNativeDatabase(url: path, readOnly: true)
                defer { database.close() }
                let rows = try database.rows("SELECT key,value FROM ItemTable WHERE key IN (?,?)", ["cursorAuth/accessToken", "cursorAuth/refreshToken"], maximum: 2)
                auth = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, Any)? in
                    guard let key = row["key"], let value = row["value"] else { return nil }
                    return (key.replacingOccurrences(of: "cursorAuth/", with: ""), value)
                })
            }
        }
        guard let token = UsageNativeJSON.text(auth?["accessToken"], maximum: 32_768) else { return false }
        var metadata: [String: [String: Any]] = [:]
        var start = now.addingTimeInterval(-180 * 86_400).timeIntervalSince1970 * 1000
        let chats = home.appendingPathComponent(".cursor/chats")
        for path in try UsageNativeFileIO.files(under: chats, extensions: ["json"]) where path.lastPathComponent == "meta.json" {
            if let object = try UsageNativeFileIO.optionalObject(path) {
                metadata[path.deletingLastPathComponent().lastPathComponent] = object
                if let created = UsageNativeJSON.date(object["createdAtMs"]) { start = min(start, created.timeIntervalSince1970 * 1000) }
            }
        }
        var events: [UsageNativeEvent] = []
        var receivedCount = 0
        var pages: Set<String> = []
        for page in 1...50 {
            var request = request("https://api2.cursor.sh/aiserver.v1.DashboardService/GetFilteredUsageEvents", token: token,
                headers: ["Content-Type": "application/json", "Connect-Protocol-Version": "1"])
            request.httpMethod = "POST"
            request.httpBody = try UsageNativeJSON.encode([
                "startDate": String(Int64(start)), "endDate": String(Int64(now.timeIntervalSince1970 * 1000)), "page": page, "pageSize": 100,
            ])
            let response = try await network.object(request)
            guard let batch = response["usageEventsDisplay"] as? [[String: Any]], response["totalUsageEventsCount"] != nil else {
                throw UsageNativeFailure.invalidInput("usage event response")
            }
            let total = try UsageNativeTokens.number(response["totalUsageEventsCount"])
            guard total <= 5000 else { throw UsageNativeFailure.capacity }
            let hash = UsageNativeJSON.hash(try UsageNativeJSON.encode(batch))
            guard pages.insert(hash).inserted || batch.isEmpty else { throw UsageNativeFailure.invalidInput("usage pagination") }
            for var row in batch {
                if let id = row["conversationId"] as? String, let local = metadata[id] {
                    row["cwd"] = local["cwd"]; row["title"] = local["title"]
                }
                let parser = UsageNativeParser(source: "cursor")
                events.append(contentsOf: try parser.consume(row).map(\.event))
            }
            receivedCount += batch.count
            if batch.isEmpty || receivedCount >= Int(total) { break }
            if page == 50 { throw UsageNativeFailure.capacity }
        }
        try archive.replaceRemote(events, key: "remote:cursor", account: UsageNativeJSON.hash(jwtSubject(token) ?? token))
        return true
    }

    private static func decodeEvents(_ value: Any?) throws -> [UsageNativeEvent] {
        guard let objects = value as? [Any], objects.count <= 100_000 else {
            throw UsageNativeFailure.invalidInput("cloud receipt cache")
        }
        return try JSONDecoder().decode([UsageNativeEvent].self, from: UsageNativeJSON.encode(objects))
    }

    private static func request(
        _ address: String, token: String, headers: [String: String] = [:], query: [String: String] = [:]
    ) -> URLRequest {
        var url = URLComponents(string: address)!
        if !query.isEmpty { url.queryItems = query.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: url.url!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("Edith/1.0", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    private static func configured(_ key: String, fallback: String, home: URL, environment: [String: String]) -> URL {
        environment[key].map { URL(fileURLWithPath: String($0.split(separator: ",").first ?? "")) } ?? home.appendingPathComponent(fallback)
    }

    private static func safeID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0)
        }
    }

    private static func nextCursor(_ response: [String: Any], seen: inout Set<String>) throws -> String? {
        guard let value = response["next_cursor"], !(value is NSNull), value as? String != "" else { return nil }
        guard let cursor = UsageNativeJSON.text(value), seen.insert(cursor).inserted else {
            throw UsageNativeFailure.invalidInput("cloud pagination cursor")
        }
        return cursor
    }

    private static func cloudDay(_ value: String) -> Date? {
        guard value.utf8.count == 10, value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil,
            let date = UsageNativeJSON.date(value + "T00:00:00Z"), dayString(date) == value else { return nil }
        return date
    }

    private static func dayString(_ value: Date) -> String {
        String(ISO8601DateFormatter().string(from: value).prefix(10))
    }

    private static func jwtSubject(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload), let object = try? UsageNativeJSON.object(data) else { return nil }
        return UsageNativeJSON.text(object["sub"])
    }
}
