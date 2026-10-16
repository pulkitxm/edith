import EdithExtensionSupport
import Foundation

@MainActor
final class HomebrewSurface {
    private let load: @Sendable () async -> HomebrewListingSnapshot?
    private var stopped = false

    init(
        store: HomebrewListingStore = HomebrewListingStore(),
        load: (@Sendable () async -> HomebrewListingSnapshot?)? = nil
    ) {
        self.load = load ?? { await store.load() }
    }

    func snapshot(_ tile: SurfaceTile) async throws -> SurfaceSnapshot {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        try Task.checkCancellation()
        let cached = await load()
        try Task.checkCancellation()
        guard !stopped else { throw ExtensionPeerError.unavailable }
        guard let cached else {
            return .init(
                providerID: "homebrew",
                sources: HomebrewPackageKind.allCases.map { .init($0.rawValue, $0.pluralTitle) },
                message: "Open Packages to load the installed inventory.")
        }
        return Self.snapshot(packages: cached.packages.values.flatMap { $0 }, tile: tile)
    }

    func shutdown() { stopped = true }

    static func snapshot(packages: [HomebrewPackage], tile: SurfaceTile, updatedAt: Date? = nil)
        -> SurfaceSnapshot
    {
        let selected = packages.filter {
            $0.installed && (tile.sourceIDs?.contains($0.kind.rawValue) ?? true)
        }
        return .init(
            providerID: "homebrew",
            metrics: [
                .init("packages", "Installed packages", selected.count.description),
                .init("updates", "Outdated", selected.filter(\.outdated).count.description),
            ],
            rows: selected.sorted { $0.outdated && !$1.outdated }.prefix(100).map {
                .init(
                    $0.id, sourceID: $0.kind.rawValue, title: String($0.displayName.prefix(1024)),
                    detail: String($0.versionSummary.prefix(4096)),
                    value: $0.outdated ? "Update available" : $0.kind.title,
                    icon: "cube.box")
            }, actions: [],
            sources: HomebrewPackageKind.allCases.map { .init($0.rawValue, $0.pluralTitle) },
            updatedAt: updatedAt)
    }
}
