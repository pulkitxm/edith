import Foundation

public enum AgentTranscriptReader {
    static let chunkSize = 4 << 20
    static let lineLimit = 2 << 20

    private static let claudeMarkers = [
        "\"type\":\"user\"", "\"type\":\"assistant\"", "\"type\":\"ai-title\"",
        "\"type\":\"pr-link\"",
    ].map { Array($0.utf8) }
    private static let codexMarkers = [
        "\"session_meta\"", "\"user_message\"", "\"agent_message\"", "\"type\":\"message\"",
        "\"turn_context\"",
    ].map { Array($0.utf8) }
    private static let piMarkers = [
        "\"type\":\"session\"", "\"type\":\"session_info\"", "\"type\":\"message\"",
    ].map { Array($0.utf8) }
    private static let toolResult = Array("\"tool_result\"".utf8)
    private static let textPart = Array("\"type\":\"text\"".utf8)

    @discardableResult
    public static func update(
        _ digest: inout AgentTranscriptDigest, url: URL, deadline: Date = .distantFuture
    ) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: digest.offset)
        var carry = Data()
        var consumed = digest.offset
        var lastStamp: String?
        var skipping = false
        var finished = true
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            carry.append(chunk)
            let used = carry.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                var start = 0
                while start < buffer.count,
                    let found = memchr(base + start, 0x0A, buffer.count - start)
                {
                    let end = base.distance(to: UnsafeRawPointer(found))
                    if skipping {
                        skipping = false
                    } else if end - start <= lineLimit {
                        let line = UnsafeRawBufferPointer(rebasing: buffer[start..<end])
                        if let stamp = consume(line, into: &digest) { lastStamp = stamp }
                    }
                    start = end + 1
                }
                return start
            }
            consumed += UInt64(used)
            carry.removeSubrange(0..<used)
            if carry.count > lineLimit {
                consumed += UInt64(carry.count)
                carry.removeAll(keepingCapacity: true)
                skipping = true
            }
            if chunk.count < chunkSize { break }
            if Date() > deadline {
                finished = false
                break
            }
        }
        digest.offset = consumed
        if let lastStamp { digest.touch(AgentTranscriptTime.parse(lastStamp)) }
        return finished
    }

    static func consume(_ line: UnsafeRawBufferPointer, into digest: inout AgentTranscriptDigest)
        -> String?
    {
        let markers: [[UInt8]] =
            switch digest.kind {
            case .claude: claudeMarkers
            case .codex: codexMarkers
            case .pi: piMarkers
            }
        guard markers.contains(where: { contains(line, $0) }) else { return nil }
        if digest.kind == .claude, contains(line, toolResult) { return nil }
        guard let base = line.baseAddress,
            let object = try? JSONSerialization.jsonObject(
                with: Data(
                    bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: line.count,
                    deallocator: .none)) as? [String: Any]
        else { return nil }
        switch digest.kind {
        case .claude: readClaude(object, line: line, into: &digest)
        case .codex: readCodex(object, into: &digest)
        case .pi: readPi(object, into: &digest)
        }
        let stamp = object["timestamp"] as? String
        if digest.firstActivity == nil, let stamp {
            digest.touch(AgentTranscriptTime.parse(stamp))
        }
        return stamp
    }

    static func readClaude(
        _ object: [String: Any], line: UnsafeRawBufferPointer,
        into digest: inout AgentTranscriptDigest
    ) {
        if digest.sessionID.isEmpty, let session = object["sessionId"] as? String {
            digest.sessionID = session
        }
        guard object["isSidechain"] as? Bool != true else { return }
        switch object["type"] as? String {
        case "ai-title":
            if let title = object["aiTitle"] as? String {
                digest.namedTitle = AgentTranscriptDigest.clean(
                    title, limit: AgentTranscriptDigest.titleLimit)
            }
        case "pr-link":
            if let repository = object["prRepository"] as? String,
                let number = object["prNumber"] as? Int
            {
                digest.pullRequest = "\(repository)#\(number)"
            }
        case "user":
            if let cwd = object["cwd"] as? String, !cwd.isEmpty { digest.cwd = cwd }
            if let branch = object["gitBranch"] as? String, !branch.isEmpty,
                branch != "HEAD"
            {
                digest.branch = branch
            }
            guard object["isMeta"] as? Bool != true,
                object["isCompactSummary"] as? Bool != true,
                let message = object["message"] as? [String: Any]
            else { return }
            for text in texts(message["content"]) where !isInjected(text) {
                digest.addPrompt(text)
            }
        case "assistant":
            guard contains(line, textPart), let message = object["message"] as? [String: Any]
            else { return }
            for text in texts(message["content"]) { digest.addReply(text) }
        default:
            break
        }
    }

    static func readCodex(_ object: [String: Any], into digest: inout AgentTranscriptDigest) {
        let payload = object["payload"] as? [String: Any] ?? [:]
        switch object["type"] as? String {
        case "session_meta":
            if let id = payload["id"] as? String { digest.sessionID = id }
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty { digest.cwd = cwd }
            if let git = payload["git"] as? [String: Any], let branch = git["branch"] as? String,
                !branch.isEmpty
            {
                digest.branch = branch
            }
        case "turn_context":
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty { digest.cwd = cwd }
        case "event_msg":
            switch payload["type"] as? String {
            case "user_message":
                if let text = payload["message"] as? String, !isInjected(text) {
                    digest.addPrompt(text)
                }
            case "agent_message":
                if let text = payload["message"] as? String { digest.addReply(text) }
            default:
                break
            }
        case "response_item":
            guard payload["type"] as? String == "message" else { return }
            switch payload["role"] as? String {
            case "user":
                for text in texts(payload["content"]) where !isInjected(text) {
                    digest.addPrompt(text)
                }
            case "assistant":
                for text in texts(payload["content"]) { digest.addReply(text) }
            default:
                break
            }
        default:
            break
        }
    }

    static func readPi(_ object: [String: Any], into digest: inout AgentTranscriptDigest) {
        switch object["type"] as? String {
        case "session":
            if let id = object["id"] as? String { digest.sessionID = id }
            if let cwd = object["cwd"] as? String, !cwd.isEmpty { digest.cwd = cwd }
        case "session_info":
            if let name = object["name"] as? String, !name.isEmpty {
                digest.namedTitle = AgentTranscriptDigest.clean(
                    name, limit: AgentTranscriptDigest.titleLimit)
            }
        case "message":
            guard let message = object["message"] as? [String: Any] else { return }
            switch message["role"] as? String {
            case "user":
                for text in texts(message["content"]) where !isInjected(text) {
                    digest.addPrompt(text)
                }
            case "assistant":
                for text in texts(message["content"]) { digest.addReply(text) }
            default:
                break
            }
        default:
            break
        }
    }

    static func texts(_ content: Any?) -> [String] {
        if let text = content as? String { return [text] }
        guard let parts = content as? [[String: Any]] else { return [] }
        return parts.compactMap { part in
            guard let type = part["type"] as? String,
                ["text", "input_text", "output_text"].contains(type)
            else { return nil }
            return part["text"] as? String
        }
    }

    static func isInjected(_ text: String) -> Bool {
        let trimmed = text.drop(while: \.isWhitespace)
        return trimmed.hasPrefix("<") || trimmed.hasPrefix("# AGENTS.md")
            || trimmed.hasPrefix("Caveat:")
    }

    static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard let base = haystack.baseAddress, haystack.count >= needle.count else { return false }
        return needle.withUnsafeBytes { pattern in
            memmem(base, haystack.count, pattern.baseAddress, pattern.count) != nil
        }
    }
}

enum AgentTranscriptTime {
    static func parse(_ stamp: String) -> Double? {
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let date = try? fractional.parse(stamp) { return date.timeIntervalSince1970 }
        return (try? Date.ISO8601FormatStyle().parse(stamp))?.timeIntervalSince1970
    }
}
