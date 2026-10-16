import Foundation

enum UsageNativeProviderFormats {
    struct Context {
        var source: String
        var session: String
        var cwd: String
        var title: String?
        var model: String
        var timestamp: Date
    }

    static func document(_ value: Any, context: Context) throws -> [UsageNativeEvent]? {
        if context.source == "codebuff", let rows = value as? [[String: Any]] {
            return try rows.enumerated().compactMap { index, row in
                try codebuff(row, index: index, context: context)
            }
        }
        guard let row = value as? [String: Any] else { return nil }
        switch context.source {
        case "amp": return try amp(row, context: context)
        case "droid": return try droid(row, context: context).map { [$0] } ?? []
        case "gemini": return try gemini(row, context: context)
        case "qwen": return try qwen(row, context: context).map { [$0] } ?? []
        case "kimi": return try kimi(row, context: context).map { [$0] } ?? []
        case "copilot": return try copilot(row, context: context)
        default: return nil
        }
    }

    private static func event(
        context: Context, row: [String: Any], tokens: UsageNativeTokens, model: String? = nil,
        id: String? = nil, session: String? = nil, timestamp: Date? = nil, cost: Double? = nil
    ) -> UsageNativeEvent? {
        guard tokens.total > 0 || (cost ?? 0) > 0 else { return nil }
        return .init(
            source: context.source,
            identity: id ?? UsageNativeJSON.text(row["id"] ?? row["messageId"]),
            session: session ?? UsageNativeJSON.text(row["sessionId"] ?? row["session_id"])
                ?? context.session,
            model: model ?? UsageNativeJSON.text(row["model"]) ?? context.model,
            timestamp: timestamp ?? UsageNativeJSON.date(row["timestamp"] ?? row["createdAt"])
                ?? context.timestamp,
            cwd: UsageNativeJSON.text(row["cwd"] ?? row["directory"]) ?? context.cwd,
            title: UsageNativeJSON.title(row["title"]) ?? context.title,
            tokens: tokens, recordedCost: cost)
    }

    private static func number(_ row: [String: Any], _ keys: String...) throws -> Double {
        for key in keys where row[key] != nil { return try UsageNativeTokens.wireNumber(row[key]) }
        return 0
    }

    private static func totalFallback(
        _ tokens: UsageNativeTokens, total: Any?, reasoning: Double = 0
    ) throws -> UsageNativeTokens {
        var result = tokens
        let reported = try UsageNativeTokens.number(total)
        result.output += max(reasoning, max(0, reported - tokens.total))
        return result
    }

    private static func amp(_ row: [String: Any], context: Context) throws -> [UsageNativeEvent] {
        guard let id = UsageNativeJSON.text(row["id"]),
            let messages = row["messages"] as? [[String: Any]]
        else { return [] }
        if let ledger = row["usageLedger"] as? [String: Any],
            let records = ledger["events"] as? [[String: Any]]
        {
            return try records.compactMap { record in
                guard let values = record["tokens"] as? [String: Any],
                    let model = UsageNativeJSON.text(record["model"]),
                    let timestamp = UsageNativeJSON.date(record["timestamp"])
                else { return nil }
                let target = String(describing: record["toMessageId"] ?? "")
                let usage =
                    messages.first { String(describing: $0["messageId"] ?? "") == target }?["usage"]
                    as? [String: Any] ?? [:]
                let tokens = try totalFallback(
                    .init(
                        input: number(values, "input"), output: number(values, "output"),
                        creation: number(usage, "cacheCreationInputTokens"),
                        read: number(usage, "cacheReadInputTokens")), total: values["total"])
                let receipt = record["id"].map { String(describing: $0) }
                return event(
                    context: context, row: record, tokens: tokens, model: model,
                    id: receipt.map { id + ":" + $0 }, session: id, timestamp: timestamp)
            }
        }
        return try messages.compactMap { message in
            guard message["role"] as? String == "assistant",
                let usage = message["usage"] as? [String: Any],
                let timestamp = UsageNativeJSON.date(usage["timestamp"] ?? message["timestamp"])
            else { return nil }
            let tokens = try totalFallback(
                .init(
                    input: number(usage, "inputTokens"), output: number(usage, "outputTokens"),
                    creation: number(usage, "cacheCreationInputTokens"),
                    read: number(usage, "cacheReadInputTokens")), total: usage["totalTokens"])
            return event(
                context: context, row: message, tokens: tokens,
                model: UsageNativeJSON.text(usage["model"] ?? message["model"]),
                id: message["messageId"].map { id + ":" + String(describing: $0) }, session: id,
                timestamp: timestamp)
        }
    }

    private static func droid(_ row: [String: Any], context: Context) throws -> UsageNativeEvent? {
        guard let usage = row["tokenUsage"] as? [String: Any] else { return nil }
        let tokens = try totalFallback(
            .init(
                input: number(usage, "inputTokens"), output: number(usage, "outputTokens"),
                creation: number(usage, "cacheCreationTokens"),
                read: number(usage, "cacheReadTokens")), total: usage["totalTokens"],
            reasoning: number(usage, "thinkingTokens"))
        let model = UsageNativeJSON.text(row["model"])?.replacingOccurrences(
            of: "custom:", with: "")
        return event(
            context: context, row: row, tokens: tokens, model: model,
            id: "session:" + context.session,
            timestamp: UsageNativeJSON.date(row["providerLockTimestamp"]))
    }

    private static func codebuff(_ row: [String: Any], index: Int, context: Context) throws
        -> UsageNativeEvent?
    {
        guard
            ["ai", "agent", "assistant"].contains(
                row["variant"] as? String ?? row["role"] as? String ?? "")
        else { return nil }
        let metadata = row["metadata"] as? [String: Any] ?? [:]
        let block = metadata["codebuff"] as? [String: Any] ?? [:]
        var usage = metadata["usage"] as? [String: Any] ?? block["usage"] as? [String: Any] ?? [:]
        if usage.isEmpty,
            let run = metadata["runState"] as? [String: Any],
            let session = run["sessionState"] as? [String: Any],
            let state = session["mainAgentState"] as? [String: Any],
            let history = state["messageHistory"] as? [[String: Any]]
        {
            for message in history.reversed() where message["role"] as? String == "assistant" {
                let options = message["providerOptions"] as? [String: Any] ?? [:]
                let block = options["codebuff"] as? [String: Any] ?? [:]
                if let found = options["usage"] as? [String: Any] ?? block["usage"]
                    as? [String: Any]
                {
                    usage = found; break
                }
            }
        }
        let details =
            usage["promptTokensDetails"] as? [String: Any] ?? usage["prompt_tokens_details"]
            as? [String: Any] ?? [:]
        let tokens = try totalFallback(
            .init(
                input: number(
                    usage, "inputTokens", "input_tokens", "promptTokens", "prompt_tokens"),
                output: number(
                    usage, "outputTokens", "output_tokens", "completionTokens", "completion_tokens"),
                creation: number(
                    usage, "cacheCreationInputTokens", "cache_creation_input_tokens",
                    "cacheCreationTokens"),
                read: max(
                    number(usage, "cacheReadInputTokens", "cache_read_input_tokens"),
                    number(details, "cachedTokens", "cached_tokens"))),
            total: usage["totalTokens"] ?? usage["total_tokens"] ?? usage["total"])
        return event(
            context: context, row: row, tokens: tokens,
            model: UsageNativeJSON.text(metadata["model"] ?? usage["model"]),
            id: UsageNativeJSON.text(row["id"]).map { context.session + ":" + $0 },
            timestamp: UsageNativeJSON.date(
                row["timestamp"] ?? row["createdAt"] ?? metadata["timestamp"]))
    }

    private static func gemini(_ row: [String: Any], context: Context) throws -> [UsageNativeEvent]
    {
        var context = context
        context.session =
            UsageNativeJSON.text(row["sessionId"] ?? row["session_id"]) ?? context.session
        context.timestamp =
            UsageNativeJSON.date(row["startTime"] ?? row["lastUpdated"] ?? row["timestamp"])
            ?? context.timestamp
        if let messages = row["messages"] as? [[String: Any]] {
            return try messages.filter { $0["type"] as? String == "gemini" }.compactMap {
                try geminiEvent(
                    $0, values: $0["tokens"] as? [String: Any] ?? [:], context: context,
                    inclusive: false)
            }
        }
        if row["type"] as? String == "gemini", let values = row["tokens"] as? [String: Any] {
            return try geminiEvent(row, values: values, context: context, inclusive: false).map {
                [$0]
            } ?? []
        }
        let stats =
            row["stats"] as? [String: Any] ?? (row["result"] as? [String: Any])?["stats"]
            as? [String: Any] ?? [:]
        if let models = stats["models"] as? [String: [String: Any]] {
            return try models.keys.sorted().compactMap { model in
                var record = row; record["model"] = model
                return try geminiEvent(
                    record, values: models[model]?["tokens"] as? [String: Any] ?? [:],
                    context: context, inclusive: true)
            }
        }
        return try geminiEvent(row, values: stats, context: context, inclusive: true).map { [$0] }
            ?? []
    }

    private static func geminiEvent(
        _ row: [String: Any], values: [String: Any], context: Context, inclusive: Bool
    ) throws -> UsageNativeEvent? {
        let input = try number(values, "input", "prompt", "input_tokens", "prompt_tokens")
        let output = try number(
            values, "output", "candidates", "output_tokens", "candidates_tokens")
        let read = try number(values, "cached", "cached_tokens")
        let reasoning = try number(
            values, "thoughts", "reasoning", "thoughts_tokens", "reasoning_tokens")
        let tool = try number(values, "tool", "tool_tokens")
        let total = try number(values, "total", "total_tokens")
        let overlap = inclusive || (read > 0 && total == input + output + reasoning + tool)
        let tokens = try totalFallback(
            .init(
                input: max(0, input - (overlap ? min(input, read) : 0)) + tool,
                output: output, read: read), total: values["total"] ?? values["total_tokens"],
            reasoning: reasoning)
        return event(context: context, row: row, tokens: tokens)
    }

    private static func qwen(_ row: [String: Any], context: Context) throws -> UsageNativeEvent? {
        guard row["type"] as? String == "assistant",
            let usage = row["usageMetadata"] as? [String: Any]
        else { return nil }
        let tokens = try totalFallback(
            .init(
                input: number(usage, "promptTokenCount"),
                output: number(usage, "candidatesTokenCount"),
                read: number(usage, "cachedContentTokenCount")), total: usage["totalTokenCount"],
            reasoning: number(usage, "thoughtsTokenCount"))
        return event(context: context, row: row, tokens: tokens)
    }

    private static func kimi(_ row: [String: Any], context: Context) throws -> UsageNativeEvent? {
        let usage: [String: Any]
        var id: String?
        if row["type"] as? String == "usage.record" {
            guard row["usageScope"] as? String == "turn",
                let values = row["usage"] as? [String: Any]
            else { return nil }
            usage = values
        } else {
            guard let message = row["message"] as? [String: Any],
                message["type"] as? String == "StatusUpdate",
                let payload = message["payload"] as? [String: Any],
                let values = payload["token_usage"] as? [String: Any]
            else { return nil }
            usage = values; id = UsageNativeJSON.text(payload["message_id"])
        }
        let tokens = try totalFallback(
            .init(
                input: number(usage, "inputOther", "input_other"), output: number(usage, "output"),
                creation: number(usage, "inputCacheCreation", "input_cache_creation"),
                read: number(usage, "inputCacheRead", "input_cache_read")), total: usage["total"])
        return event(
            context: context, row: row, tokens: tokens,
            model: UsageNativeJSON.text(row["model"]) ?? "kimi-for-coding", id: id,
            timestamp: UsageNativeJSON.date(row["time"] ?? row["timestamp"]))
    }

    private static func normalizedCopilotModel(_ value: String) -> String {
        for suffix in ["-1m-internal", "-1m"] where value.hasSuffix(suffix) {
            return String(value.dropLast(suffix.count))
        }
        return value
    }

    private static func copilot(_ row: [String: Any], context: Context) throws -> [UsageNativeEvent]
    {
        if row["type"] as? String == "session.shutdown", let data = row["data"] as? [String: Any],
            let models = data["modelMetrics"] as? [String: [String: Any]]
        {
            return try models.keys.sorted().compactMap { model in
                guard let usage = models[model]?["usage"] as? [String: Any] else { return nil }
                let inclusive = try number(usage, "inputTokens")
                let read = try number(usage, "cacheReadTokens")
                let creation = try number(usage, "cacheWriteTokens")
                let tokens = try UsageNativeTokens(
                    input: max(0, inclusive - read - creation),
                    output: number(usage, "outputTokens") + number(usage, "reasoningTokens"),
                    creation: number(usage, "cacheWriteTokens"),
                    read: number(usage, "cacheReadTokens"))
                var result = event(
                    context: context, row: row, tokens: tokens,
                    model: normalizedCopilotModel(model),
                    id: "shutdown:" + context.session + ":" + model)
                result?.observationPriority = 4
                return result
            }
        }
        guard let values = row["attributes"] as? [String: Any] else { return [] }
        let span =
            row["type"] as? String == "span"
            || row["name"] != nil
                && (row["spanId"] != nil || row["traceId"] != nil || row["startTime"] != nil)
        let operation = values["gen_ai.operation.name"] as? String ?? ""
        let name = row["name"] as? String ?? ""
        let body = row["body"] as? String ?? row["_body"] as? String ?? ""
        let priority: Int
        if span, operation == "chat" || name.hasPrefix("chat ") {
            priority = 0
        } else if !span,
            values["event.name"] as? String == "gen_ai.client.inference.operation.details"
                || body.hasPrefix("GenAI inference:")
        {
            priority = 1
        } else if !span,
            values["event.name"] as? String == "copilot_chat.agent.turn"
                || body.hasPrefix("copilot_chat.agent.turn")
        {
            priority = 2
        } else if span, operation == "invoke_agent" || name.hasPrefix("invoke_agent ") {
            priority = 3
        } else {
            return []
        }
        let input = try number(values, "gen_ai.usage.input_tokens", "gen_ai.usage.prompt_tokens")
        let read = try number(
            values, "gen_ai.usage.cache_read.input_tokens", "gen_ai.usage.cache_read_tokens")
        let creation = try number(
            values, "gen_ai.usage.cache_write.input_tokens",
            "gen_ai.usage.cache_creation.input_tokens", "gen_ai.usage.cache_write_tokens")
        let tokens = try totalFallback(
            UsageNativeTokens(
                input: max(0, input - read),
                output: number(
                    values, "gen_ai.usage.output_tokens", "gen_ai.usage.completion_tokens"),
                creation: creation, read: read),
            total: values["gen_ai.usage.total_tokens"] ?? values["gen_ai.usage.total.token_count"])
        var timestamp = UsageNativeJSON.date(row["timestamp"] ?? row["startTime"] ?? row["endTime"])
        if let array = row["startTime"] as? [Double], array.count == 2 {
            timestamp = Date(timeIntervalSince1970: array[0] + array[1] / 1e9)
        }
        let session =
            UsageNativeJSON.text(
                values["gen_ai.conversation.id"] ?? values["copilot_chat.session_id"] ?? values[
                    "copilot_chat.chat_session_id"] ?? values["session.id"]
                    ?? values["github.copilot.interaction_id"]) ?? context.session
        let id = UsageNativeJSON.text(values["gen_ai.response.id"] ?? row["spanId"])
        var result = event(
            context: context, row: row, tokens: tokens,
            model: UsageNativeJSON.text(
                values["gen_ai.response.model"] ?? values["gen_ai.request.model"]
            ).map(normalizedCopilotModel),
            id: id, session: session, timestamp: timestamp)
        result?.observationPriority = priority
        result?.traceID = UsageNativeJSON.text(
            row["traceId"] ?? (row["spanContext"] as? [String: Any])?["traceId"])
        result?.receiptID = UsageNativeJSON.text(values["gen_ai.response.id"])
        return result.map { [$0] } ?? []
    }
}
