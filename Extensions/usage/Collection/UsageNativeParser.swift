import Foundation

final class UsageNativeParser {
    private var session = ""
    private var cwd = ""
    private var model: String
    private var tier: String?
    private var title: String?
    private var titles: [String: String] = [:]
    private var prior: UsageNativeTokens?
    private var modern: [UsageNativeParsedRecord] = []
    private var legacy: [UsageNativeParsedRecord] = []
    private var seenResponses: Set<String> = []
    private var child = false
    private var childTurn = false
    private let source: String

    init(source: String, model: String = "gpt-5", tier: String? = nil) {
        self.source = source; self.model = model; self.tier = tier
    }

    func snapshot(
        _ path: URL, key: String, previous: UsageNativeArchive.KnownFile?,
        limits: UsageNativeFileLimits = .init()
    ) throws -> UsageNativeFileSnapshot {
        session = path.deletingPathExtension().lastPathComponent
        let properties = try UsageNativeFileIO.lines(
            path, previousBytes: previous?.size ?? 0, limits: limits
        ) {
            data, offset, end in
            guard let row = try? UsageNativeJSON.object(data) else { return }
            let records = try self.consume(row, offset: offset, end: end)
            self.legacy.append(contentsOf: records)
            guard self.legacy.count + self.modern.count <= limits.records else {
                throw UsageNativeFailure.capacity
            }
        }
        let selected = source == "codex" && !modern.isEmpty ? modern : legacy
        let records = selected.map { record -> UsageNativeParsedRecord in
            var event = record.event
            if event.title == nil { event.title = titles[event.session] ?? title }
            if event.cwd.isEmpty { event.cwd = cwd }
            return .init(offset: record.offset, end: record.end, event: event)
        }
        return .init(
            path: key, size: properties.0, completeBytes: properties.1, modified: properties.2,
            hash: properties.3, prefixHash: properties.4, records: records)
    }

    func consume(_ original: [String: Any], offset: Int = 0, end: Int = 0) throws
        -> [UsageNativeParsedRecord]
    {
        var row = original
        if let wrapper = row["data"] as? [String: Any],
            let nested = wrapper["message"] as? [String: Any], nested["message"] != nil
        {
            row = nested
        }
        if let value = UsageNativeJSON.text(row["cwd"]) { cwd = value }
        if let value = UsageNativeJSON.text(row["sessionId"] ?? row["sessionID"] ?? row["sid"]) {
            session = value
        }
        if let name = UsageNativeJSON.title(row["aiTitle"] ?? row["title"]) {
            titles[session] = name; title = name
        }
        if row["type"] as? String == "user" {
            if titles[session] == nil,
                let text = Self.contentTitle((row["message"] as? [String: Any])?["content"])
            {
                titles[session] = text
            }
            return []
        }
        let event: UsageNativeEvent?
        switch source {
        case "cli", "cowork", "claude-cloud": event = try anthropic(row)
        case "codex": event = try codex(row, offset: offset, end: end)
        case "opencode": event = try openCode(row)
        case "cursor": event = try cursor(row)
        default: event = try generic(row)
        }
        guard let event, event.tokens.total > 0 || (event.recordedCost ?? 0) > 0 else { return [] }
        return [.init(offset: offset, end: end, event: event)]
    }

    func anthropic(_ row: [String: Any]) throws -> UsageNativeEvent? {
        guard row["type"] == nil || row["type"] as? String == "assistant",
            let message = row["message"] as? [String: Any],
            let usage = message["usage"] as? [String: Any],
            row["isApiErrorMessage"] as? Bool != true,
            let timestamp = UsageNativeJSON.date(row["timestamp"]),
            let model = UsageNativeJSON.text(message["model"]), !model.hasPrefix("<synthetic>")
        else { return nil }
        let receipt = UsageNativeJSON.text(message["id"])
        let identity = receipt.map {
            $0 + ":" + (UsageNativeJSON.text(row["requestId"]) ?? "") + ":"
                + String(row["isSidechain"] as? Bool ?? false)
        }
        return try .init(
            source: source, identity: identity, session: session, model: model,
            timestamp: timestamp, cwd: cwd, title: titles[session],
            tokens: .anthropic(usage), recordedCost: UsageNativeTokens.amount(row["costUSD"]),
            serviceTier: UsageNativeJSON.text(usage["speed"]), receiptID: receipt)
    }

    private func codex(_ row: [String: Any], offset: Int, end: Int) throws -> UsageNativeEvent? {
        let payload = row["payload"] as? [String: Any] ?? [:]
        let type = row["type"] as? String ?? ""
        if type == "session_meta" {
            session = UsageNativeJSON.text(payload["id"]) ?? session
            cwd = UsageNativeJSON.text(payload["cwd"]) ?? cwd
            child =
                payload["forked_from_id"] != nil
                || (payload["source"] as? [String: Any])?["subagent"] != nil
            if let value = UsageNativeJSON.text(payload["model"]) { model = value }
            return nil
        }
        if type == "turn_context" {
            model = UsageNativeJSON.text(payload["model"]) ?? model
            if let value = UsageNativeJSON.text(payload["service_tier"]) { tier = value }
            cwd = UsageNativeJSON.text(payload["cwd"]) ?? cwd
            return nil
        }
        let eventType = payload["type"] as? String ?? type
        if eventType == "task_started" { childTurn = true; return nil }
        if eventType == "thread_settings_applied" {
            tier = UsageNativeJSON.text(
                payload["service_tier"] ?? (payload["settings"] as? [String: Any])?["service_tier"])
            return nil
        }
        if eventType == "user_message" {
            if title == nil { title = UsageNativeJSON.title(payload["message"]) }
            return nil
        }
        guard let timestamp = UsageNativeJSON.date(row["timestamp"]) else { return nil }
        if type == "token_usage_record" {
            guard let usage = payload["usage"] as? [String: Any],
                let response = UsageNativeJSON.text(payload["response_id"]),
                payload["thread_id"] == nil || payload["thread_id"] as? String == session
            else { return nil }
            guard usage["input_tokens"] != nil, usage["output_tokens"] != nil else {
                throw UsageNativeFailure.invalidInput("per-request receipt")
            }
            guard seenResponses.insert(response).inserted else { return nil }
            let event = try UsageNativeEvent(
                source: source, identity: response, session: session,
                model: UsageNativeJSON.text(payload["model"] ?? payload["model_name"]) ?? model,
                timestamp: timestamp, cwd: cwd, title: title, tokens: .openAI(usage),
                recordedCost: UsageNativeTokens.amount(payload["costUSD"] ?? payload["cost_usd"]),
                serviceTier: UsageNativeJSON.text(payload["service_tier"]) ?? tier,
                estimated: payload["model"] == nil && model == "gpt-5", receiptID: response)
            modern.append(.init(offset: offset, end: end, event: event))
            return nil
        }
        guard eventType == "token_count", let info = payload["info"] as? [String: Any] else {
            return nil
        }
        let total = try (info["total_token_usage"] as? [String: Any]).map {
            try UsageNativeTokens.openAI($0)
        }
        let last = try (info["last_token_usage"] as? [String: Any]).map {
            try UsageNativeTokens.openAI($0)
        }
        let tokens: UsageNativeTokens
        if let total {
            if child, !childTurn { prior = total; return nil }
            if let prior, total.total >= prior.total {
                tokens = total - prior
            } else {
                tokens = last ?? total
            }
            prior = total
        } else if let last {
            tokens = last
        } else {
            return nil
        }
        guard tokens.total > 0 else { return nil }
        return .init(
            source: source, identity: "legacy:" + session + ":" + String(offset),
            session: session, model: model, timestamp: timestamp, cwd: cwd, title: title,
            tokens: tokens, recordedCost: nil, serviceTier: tier, estimated: model == "gpt-5")
    }

    func openCode(_ row: [String: Any]) throws -> UsageNativeEvent? {
        guard row["role"] as? String == "assistant" || row["type"] as? String == "assistant",
            let usage = row["tokens"] as? [String: Any],
            let timestamp = UsageNativeJSON.date(
                (row["time"] as? [String: Any])?["created"] ?? row["time_created"])
        else { return nil }
        let cache = usage["cache"] as? [String: Any] ?? [:]
        let tokens = try UsageNativeTokens(
            input: UsageNativeTokens.number(usage["input"]),
            output: UsageNativeTokens.number(usage["output"])
                + UsageNativeTokens.number(usage["reasoning"]),
            creation: UsageNativeTokens.number(cache["write"]),
            read: UsageNativeTokens.number(cache["read"]))
        let model =
            UsageNativeJSON.text(row["modelID"] ?? (row["model"] as? [String: Any])?["id"])
            ?? "unknown"
        let cwd =
            UsageNativeJSON.text((row["path"] as? [String: Any])?["cwd"] ?? row["directory"]) ?? cwd
        return try .init(
            source: source, identity: UsageNativeJSON.text(row["id"]),
            session: UsageNativeJSON.text(row["sessionID"] ?? row["session_id"]) ?? session,
            model: model, timestamp: timestamp, cwd: cwd, title: title,
            tokens: tokens, recordedCost: UsageNativeTokens.amount(row["cost"]))
    }

    func cursor(_ row: [String: Any]) throws -> UsageNativeEvent? {
        guard let timestamp = UsageNativeJSON.date(row["timestamp"]),
            let usage = row["tokenUsage"] as? [String: Any]
        else { return nil }
        let session = UsageNativeJSON.text(row["conversationId"]) ?? session
        let model = UsageNativeJSON.text(row["model"]) ?? "unknown"
        let tokens = try UsageNativeTokens(
            input: UsageNativeTokens.number(usage["inputTokens"]),
            output: UsageNativeTokens.number(usage["outputTokens"]),
            creation: UsageNativeTokens.number(usage["cacheWriteTokens"]),
            read: UsageNativeTokens.number(usage["cacheReadTokens"]))
        let cents = try UsageNativeTokens.amount(row["chargedCents"] ?? usage["totalCents"])
        return .init(
            source: source,
            identity: UsageNativeJSON.text(row["id"]) ?? session + ":"
                + String(timestamp.timeIntervalSince1970) + ":" + model,
            session: session, model: model, timestamp: timestamp, cwd: cwd, title: title,
            tokens: tokens, recordedCost: cents.map { $0 / 100 })
    }

    private func generic(_ row: [String: Any]) throws -> UsageNativeEvent? {
        if row["type"] as? String == "session" {
            session = UsageNativeJSON.text(row["id"]) ?? session;
            cwd = UsageNativeJSON.text(row["cwd"]) ?? cwd
            return nil
        }
        if row["type"] as? String == "session_info" {
            title = UsageNativeJSON.title(row["name"]); return nil
        }
        let message = row["message"] as? [String: Any] ?? row
        if message["role"] as? String == "user" {
            if title == nil { title = Self.contentTitle(message["content"]) }
            return nil
        }
        let usage = message["usage"] as? [String: Any] ?? row["usage"] as? [String: Any]
        guard let usage,
            let timestamp = UsageNativeJSON.date(row["timestamp"] ?? message["timestamp"])
        else { return nil }
        let tokens: UsageNativeTokens
        if usage["input_tokens"] != nil {
            tokens = try .anthropic(usage)
        } else {
            tokens = try .init(
                input: UsageNativeTokens.number(usage["input"] ?? usage["inputTokens"]),
                output: UsageNativeTokens.number(usage["output"] ?? usage["outputTokens"]),
                creation: UsageNativeTokens.number(
                    usage["cacheWrite"] ?? usage["cacheWriteTokens"]),
                read: UsageNativeTokens.number(usage["cacheRead"] ?? usage["cacheReadTokens"]))
        }
        let cost = try UsageNativeTokens.amount(
            (usage["cost"] as? [String: Any])?["total"] ?? usage["costUsd"] ?? row["costUSD"])
        return .init(
            source: source,
            identity: UsageNativeJSON.text(row["id"] ?? message["id"]) ?? session + ":"
                + String(timestamp.timeIntervalSince1970),
            session: session,
            model: UsageNativeJSON.text(message["model"] ?? row["model"]) ?? "unknown",
            timestamp: timestamp, cwd: cwd, title: title, tokens: tokens, recordedCost: cost)
    }

    private static func contentTitle(_ value: Any?) -> String? {
        if let value = value as? String { return UsageNativeJSON.title(value) }
        guard let value = value as? [[String: Any]] else { return nil }
        return value.first(where: { $0["type"] as? String == "text" }).flatMap {
            UsageNativeJSON.title($0["text"])
        }
    }
}
