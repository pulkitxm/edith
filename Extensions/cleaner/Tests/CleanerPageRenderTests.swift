import AppKit
import EdithExtensionUI
import SwiftUI
import Testing

@testable import CleanerExtension

enum CleanerRenderFixture {
    static let now = Date(timeIntervalSince1970: 1_793_000_000)

    static let drives = [
        DriveInfo(
            id: "/", name: "Macintosh HD", totalBytes: 994_662_584_320, isRemovable: false,
            isInternal: true),
        DriveInfo(
            id: "/Volumes/Archive", name: "Archive", totalBytes: 2_000_398_934_016,
            isRemovable: true, isInternal: false),
    ]

    static func item(
        _ project: String, folder: String, megabytes: Double, days: Double,
        selected: Bool = true, worktree: WorktreeInfo? = nil
    ) -> JunkItem {
        let path = URL(fileURLWithPath: "/synthetic/Developer/\(project)/\(folder)")
        return JunkItem(
            id: path.path, name: "~/Developer/\(project)/\(folder)", path: path,
            sizeBytes: Int64(megabytes * 1_048_576), selected: selected,
            lastModified: now.addingTimeInterval(-days * 86_400), worktree: worktree)
    }

    static let categories = [
        JunkCategory(
            id: "nodeModules", name: "node_modules",
            detail: "JavaScript dependencies, restored by install.",
            items: [
                item("storefront", folder: "node_modules", megabytes: 1_840, days: 41),
                item("design-tokens", folder: "node_modules", megabytes: 612, days: 96),
                item("landing", folder: "node_modules", megabytes: 388, days: 12),
            ]),
        JunkCategory(
            id: "swiftBuild", name: "Swift and Xcode build output",
            detail: "SwiftPM .build folders and project DerivedData.",
            items: [
                item("weather-kit", folder: ".build", megabytes: 2_310, days: 8),
                item("pocket-notes", folder: ".build", megabytes: 744, days: 63),
            ]),
        JunkCategory(
            id: "rustTarget", name: "Cargo target",
            detail: "Rust build output, rebuilt on next build.",
            items: [item("ray-tracer", folder: "target", megabytes: 3_120, days: 120)]),
        JunkCategory(
            id: Worktrees.categoryID, name: "Git worktrees",
            detail: "Extra checkouts whose branches are merged or gone.",
            items: [
                item(
                    "storefront-worktrees", folder: "checkout-redesign", megabytes: 512,
                    days: 30, selected: false,
                    worktree: WorktreeInfo(
                        branch: "feature/checkout-redesign", repository: "/synthetic/storefront",
                        unpushed: 2, merged: true)),
                item(
                    "storefront-worktrees", folder: "fix-tax-rounding", megabytes: 220, days: 54,
                    worktree: WorktreeInfo(
                        branch: "fix/tax-rounding", repository: "/synthetic/storefront",
                        dirty: false, upstreamGone: true)),
            ]),
        JunkCategory(
            id: "pycache", name: "Python caches",
            detail: "Bytecode, pytest, mypy, ruff, tox and notebook checkpoints.",
            items: [item("data-notebooks", folder: "__pycache__", megabytes: 46, days: 22)]),
    ]

}

@MainActor
@Suite(.serialized)
struct CleanerPageRenderTests {
    static func model(
        categories: [JunkCategory] = CleanerRenderFixture.categories, holdScan: Bool = false,
        holdClean: Bool = false
    ) throws -> CleanerModel {
        let defaults = try #require(
            UserDefaults(suiteName: "synthetic.cleaner.render." + UUID().uuidString))
        let now = CleanerRenderFixture.now
        let drives = CleanerRenderFixture.drives
        return CleanerModel(
            defaults: defaults,
            services: CleanerServices(
                drives: { drives },
                scan: { _, token, progress in
                    progress("~/Developer/storefront")
                    while holdScan, !token.isCancelled {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    return CleanerScanResult(categories: categories)
                },
                clean: { items, token in
                    while holdClean, !token.isCancelled {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    let bytes = items.reduce(0) { $0 + $1.sizeBytes }
                    return CleanerCleanResult(
                        items: items.count, requestedBytes: bytes, reclaimedBytes: bytes)
                }),
            now: { now })
    }

    static func capture(_ name: String, model: CleanerModel) async throws {
        for variant in CleanerRenderCapture.variants {
            _ = try await CleanerRenderCapture.render(name, variant: variant) {
                CleanerPage(model: model)
            }
        }
    }

    @Test func firstRunExplainsWhatHappensAndOffersOneScanAction() async throws {
        let model = try Self.model()
        #expect(model.presentation == .firstRun)
        try await Self.capture("cleaner-first-run", model: model)
        await model.shutdown()
    }

    @Test func scanningShowsProgressAndSkeletonInsteadOfAVoid() async throws {
        let model = try Self.model(holdScan: true)
        model.scan()
        for _ in 0..<100 where model.drives.isEmpty || model.logs.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.presentation == .scanning)
        #expect(!model.drives.isEmpty)
        try await Self.capture("cleaner-scanning", model: model)
        await model.shutdown()
    }

    @Test func resultsListCategoriesWithTotalsAndOneCleanAction() async throws {
        let model = try Self.model()
        model.scan()
        await model.finishWork()
        model.toggleExpand(Worktrees.categoryID)
        #expect(model.presentation == .results)
        #expect(model.reclaimableTotal > 0)
        try await Self.capture("cleaner-results", model: model)
        await model.shutdown()
    }

    @Test func cleaningKeepsResultsVisibleWhileItemsMove() async throws {
        let model = try Self.model(holdClean: true)
        model.scan()
        await model.finishWork()
        model.clean()
        #expect(model.scanning)
        #expect(model.presentation == .results)
        try await Self.capture("cleaner-cleaning", model: model)
        await model.shutdown()
    }

    @Test func nothingToCleanIsACalmCenteredState() async throws {
        let model = try Self.model(categories: [])
        model.scan()
        await model.finishWork()
        #expect(model.presentation == .nothingToClean)
        try await Self.capture("cleaner-nothing", model: model)
        await model.shutdown()
    }

    @Test func drivePickerListsDrivesAndFoldersWithOneConfirmAction() async throws {
        let model = try Self.model()
        model.loadDriveOptions()
        for _ in 0..<100 where model.driveOptions.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.driveOptions.count == 2)
        for variant in CleanerRenderCapture.variants where variant.width > 1000 {
            _ = try await CleanerRenderCapture.render("cleaner-picker", variant: variant) {
                ZStack {
                    Color.black.opacity(0.2)
                    DrivePickerSheet(
                        model: model, dark: variant.scheme == .dark,
                        confirmTitle: "Scan these locations", onConfirm: {}
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        await model.shutdown()
    }
}
