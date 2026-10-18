import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation

@MainActor final class QuinjetSurface {
    private let worker: QuinjetWorker
    private let privacyValues: @MainActor () -> [String: String]
    private let github: QuinjetGitHubClient
    private var urls: [String: URL] = [:]
    init(
        worker: QuinjetWorker,
        github: QuinjetGitHubClient = .live,
        privacyValues: @escaping @MainActor () -> [String: String] = {
            ExtensionSharedState.current?.values(for: "presenter") ?? [:]
        }
    ) {
        self.worker = worker
        self.github = github
        self.privacyValues = privacyValues
    }
    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        return try await SurfaceCommandService.execute(
            providerID: "quinjet", command: command, payload: payload,
            snapshot: { try await self.snapshot($0) }, perform: { try await self.perform($0) },
            privacyValues: privacyValues)
    }
    func snapshot(_ tile: SurfaceTile) async throws -> SurfaceSnapshot {
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        let selection = try await github.selection(for: tile)
        try Task.checkCancellation()
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        urls = Dictionary(
            selection.pulls.compactMap { pull in pull.url.map { (pull.id, $0) } },
            uniquingKeysWith: { first, _ in first })
        return SurfaceSnapshot(
            providerID: "quinjet", metrics: selection.metrics,
            rows: selection.pulls.prefix(min(tile.itemLimit, 100)).map(\.row),
            sources: selection.repositories.prefix(100).map { .init($0, $0) },
            message: selection.message, updatedAt: Date())
    }
    private func perform(_ action: String) async throws {
        let parts = action.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, parts[0] == "open",
            let url = urls[String(parts[1])]
        else { throw ExtensionPeerError.invalidRequest }
        NSWorkspace.shared.open(url)
    }
}
