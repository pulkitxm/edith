import EdithKit
import Foundation

struct AttentionAgentRecorder {
    static let maximumGap: TimeInterval = 300
    static let emitInterval: TimeInterval = 20

    private struct Segment {
        var id: String
        var agent: HerdrAgent
        var startedAt: Date
        var lastSeen: Date
        var emitted: Date
    }

    private var segments: [String: Segment] = [:]

    mutating func observe(_ hosts: [HerdrHostSnapshot], now: Date) -> [AttentionEvent] {
        var events: [AttentionEvent] = []
        var seen = Set<String>()
        for host in hosts where host.reachable {
            for agent in host.agents where !agent.isTerminal {
                guard agent.status == .working || agent.status == .blocked else { continue }
                seen.insert(agent.id)
                var segment: Segment
                if let existing = segments[agent.id], existing.agent.status == agent.status,
                    now.timeIntervalSince(existing.lastSeen) <= Self.maximumGap
                {
                    segment = existing
                    segment.agent = agent
                    segment.lastSeen = now
                } else {
                    if let existing = segments[agent.id], let final = Self.flush(existing) {
                        events.append(final)
                    }
                    segment = Segment(
                        id: "agent:\(agent.id):\(Int(now.timeIntervalSince1970))",
                        agent: agent, startedAt: now, lastSeen: now, emitted: now)
                }
                if now > segment.startedAt,
                    now.timeIntervalSince(segment.emitted) >= Self.emitInterval
                        || segment.emitted == segment.startedAt
                {
                    segment.emitted = now
                    events.append(Self.event(segment))
                }
                segments[agent.id] = segment
            }
        }
        for (id, segment) in segments where !seen.contains(id) {
            if let final = Self.flush(segment) { events.append(final) }
            segments[id] = nil
        }
        return events
    }

    private static func flush(_ segment: Segment) -> AttentionEvent? {
        guard segment.lastSeen > segment.emitted || segment.emitted == segment.startedAt,
            segment.lastSeen > segment.startedAt
        else { return nil }
        return event(segment)
    }

    private static func event(_ segment: Segment) -> AttentionEvent {
        let agent = segment.agent
        var tags = [
            AttentionTag.machine: agent.machineName,
            AttentionTag.agent: HerdrKind.displayName(for: agent.kind),
            AttentionTag.session: agent.id,
            AttentionTag.status: agent.status.rawValue,
        ]
        if let project = project(agent.cwd) { tags[AttentionTag.project] = project }
        let title = agent.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return AttentionEvent(
            id: segment.id, startedAt: segment.startedAt,
            duration: segment.lastSeen.timeIntervalSince(segment.startedAt), source: .agent,
            appName: HerdrKind.displayName(for: agent.kind),
            windowTitle: title.isEmpty ? nil : String(title.prefix(300)), tags: tags)
    }

    static func project(_ cwd: String) -> String? {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let name = URL(fileURLWithPath: trimmed).lastPathComponent
        guard !name.isEmpty, name != "/", name != "~" else { return nil }
        return name
    }
}
