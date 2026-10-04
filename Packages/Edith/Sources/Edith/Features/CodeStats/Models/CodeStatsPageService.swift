import AppKit
import EdithKit
import Foundation

struct CodeStatsPageService: Sendable {
    var status: @Sendable () async throws -> CodeStatsStatus
    var report: @Sendable (CodeStatsRange) async throws -> CodeStatsReport?
    var start: @Sendable () async throws -> CodeStatsActiveRun
    var cancel: @Sendable () async throws -> CodeStatsStatus
    var profile: @Sendable () async throws -> CodeStatsProfileLookup
    var authors: @Sendable () async throws -> [CodeStatsDiscoveredAuthor]
    var checkSchedule: @Sendable () async throws -> Void
    var updates: @Sendable () -> AsyncStream<CodeStatsStatus>
    var volumeEvents: @Sendable () -> AsyncStream<Void>

    static var live: CodeStatsPageService {
        let client = CodeStatsAgentClient()
        return CodeStatsPageService(
            status: { try await client.status() },
            report: { try await client.report($0) },
            start: { try await client.start() },
            cancel: { try await client.cancel() },
            profile: { try await client.profile() },
            authors: { try await client.authors() },
            checkSchedule: {
                _ = try await AgentClient.shared.performInternalAsync(
                    AgentDiagnostics.runJob,
                    payload: AgentPayload.encode(CodeStatsAgentOperation.scheduleJob))
            },
            updates: { AgentTopicStream.values(CodeStatsStatus.self, topic: .codeStats) },
            volumeEvents: { CodeStatsVolumeEvents.stream() })
    }
}

enum CodeStatsVolumeEvents {
    static let names: [Notification.Name] = [
        NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
    ]

    static func stream(
        center: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let tokens = ObserverTokens(
                center: center,
                tokens: names.map { name in
                    center.addObserver(forName: name, object: nil, queue: nil) { _ in
                        continuation.yield()
                    }
                })
            continuation.onTermination = { _ in tokens.remove() }
        }
    }

    private final class ObserverTokens: @unchecked Sendable {
        private let center: NotificationCenter
        private let tokens: [NSObjectProtocol]

        init(center: NotificationCenter, tokens: [NSObjectProtocol]) {
            self.center = center
            self.tokens = tokens
        }

        func remove() {
            for token in tokens { center.removeObserver(token) }
        }
    }
}
