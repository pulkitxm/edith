import EdithExtensionUI
import EdithExtensionSupport
import Foundation

struct CompanionLibraryReads: Sendable {
    var episodes: @Sendable () async throws -> [CompanionEpisode]
    var episode: @Sendable (String) async throws -> CompanionEpisodeDetail
    var signals: @Sendable (String) async throws -> [CompanionSignal] = { _ in [] }
    var media: @Sendable (String) async throws -> Data? = { _ in nil }

    static var live: Self {
        Self(
            episodes: { try await client.episodes(limit: 60) },
            episode: { id in
                try await CompanionChatLibraryOperationExecution.episode(id: id) {
                    try await client.episodeDetail(id: $0)
                }
            },
            signals: { (try? await client.signals(episodeId: $0)) ?? [] },
            media: { try await client.media(episodeId: $0).0 })
    }

    private static var client: CompanionClient {
        CompanionClient(baseURL: CompanionClient.endpoint(override: nil))
    }
}
