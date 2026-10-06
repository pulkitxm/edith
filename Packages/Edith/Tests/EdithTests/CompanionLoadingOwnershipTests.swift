import Foundation
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
@Suite struct CompanionLoadingOwnershipTests {
    @Test func selectingAndClosingAnEpisodeSuppressesLateResults() async {
        let requests = EpisodeRequests()
        let model = CompanionLibraryModel(
            reads: .init(
                episodes: { [] }, episode: { await requests.read($0) }))
        let first = Task { await model.select("first") }
        await requests.started("first")
        let second = Task { await model.select("second") }
        await requests.started("second")
        await requests.finish("second")
        await second.value
        #expect(model.detail?.id == "second")
        await requests.finish("first")
        await first.value
        #expect(model.detail?.id == "second")
        let closing = Task { await model.select("closing") }
        await requests.started("closing")
        model.closeDetail()
        await requests.finish("closing")
        await closing.value
        #expect(model.selectedId == nil)
        #expect(model.detail == nil)
        #expect(!model.loadingDetail)
    }

    @Test func anEpisodeFailureCanRetryTheSameSelection() async {
        let attempts = EpisodeAttempts()
        let model = CompanionLibraryModel(
            reads: .init(
                episodes: { [] }, episode: { try await attempts.read($0) }))
        await model.select("retry")
        #expect(model.detailLoad.state == .error)
        #expect(model.detail == nil)
        await model.select("retry", retry: true)
        #expect(model.detail?.id == "retry")
        #expect(model.detailLoad.state == .content)
        #expect(model.error == nil)
    }

    @Test func cancellationLeavesAnInitialListRecoverableOnReentry() async {
        let requests = EpisodeRequests()
        let model = CompanionLibraryModel(
            reads: .init(
                episodes: {
                    _ = await requests.read("list")
                    return []
                }, episode: { Self.episode($0) }))
        let pending = Task { await model.refresh() }
        await requests.started("list")
        pending.cancel()
        await requests.finish("list")
        await pending.value
        #expect(model.loading.state == .cancelled)
        #expect(!model.loaded)
        let reentry = Task { await model.refresh() }
        await requests.started("list")
        await requests.finish("list")
        await reentry.value
        #expect(model.loaded)
        #expect(model.loading.state == .content)
    }

    private actor EpisodeAttempts {
        private var count = 0

        func read(_ id: String) throws -> CompanionEpisodeDetail {
            count += 1
            if count == 1 { throw CocoaError(.fileReadUnknown) }
            return episode(id)
        }
    }

    private actor EpisodeRequests {
        private var requests: [String: CheckedContinuation<CompanionEpisodeDetail, Never>] = [:]
        private var waiting: [String: CheckedContinuation<Void, Never>] = [:]

        func read(_ id: String) async -> CompanionEpisodeDetail {
            await withCheckedContinuation { continuation in
                requests[id] = continuation
                waiting.removeValue(forKey: id)?.resume()
            }
        }

        func started(_ id: String) async {
            if requests[id] != nil { return }
            await withCheckedContinuation { waiting[id] = $0 }
        }

        func finish(_ id: String) {
            requests.removeValue(forKey: id)?.resume(returning: episode(id))
        }
    }

    nonisolated private static func episode(_ id: String) -> CompanionEpisodeDetail {
        CompanionEpisodeDetail(
            id: id, occurredAt: "2026-10-01", ingestedAt: "2026-10-01", kind: "markdown",
            title: "Sample episode", body: "Synthetic notes", bodyEn: nil, langs: ["en"],
            durationS: nil, mediaRef: nil, sha256: "sample", bytes: 15, chunks: 1)
    }
}
