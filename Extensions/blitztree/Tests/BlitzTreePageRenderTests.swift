import AppKit
import EdithExtensionUI
import SwiftUI
import Testing

@testable import BlitzTreeExtension

enum BlitzTreeRenderFixture {
    static let root = "/synthetic/Users/alex"
    static let gigabyte: UInt64 = 1_073_741_824

    static func entry(
        _ name: String, gigabytes: Double, directory: Bool = true, reason: String? = nil,
        inode: UInt64
    ) -> BlitzTreeReport.Entry {
        let bytes = UInt64(gigabytes * Double(gigabyte))
        return BlitzTreeReport.Entry(
            path: root + "/" + name, kind: directory ? "directory" : "file",
            allocatedBytes: bytes, logicalBytes: bytes, fileCount: directory ? 1_200 : 1,
            complete: true, reason: reason, device: 1, inode: inode)
    }

    static let children = [
        entry("Library", gigabytes: 48.2, inode: 1),
        entry("Developer", gigabytes: 31.6, inode: 2),
        entry("Movies", gigabytes: 18.4, inode: 3),
        entry("Pictures", gigabytes: 9.1, inode: 4),
        entry("Downloads", gigabytes: 6.3, inode: 5),
        entry("Music", gigabytes: 3.2, inode: 6),
        entry("Documents", gigabytes: 2.4, inode: 7),
        entry("Desktop", gigabytes: 0.9, inode: 8),
        entry("ubuntu-24.04.iso", gigabytes: 5.7, directory: false, inode: 9),
    ]

    static let candidates = [
        entry(
            "Developer/storefront/node_modules", gigabytes: 1.8,
            reason: "JavaScript dependencies, restored by install", inode: 20),
        entry(
            "Library/Developer/Xcode/DerivedData", gigabytes: 12.4,
            reason: "Xcode build data, rebuilt when you build", inode: 21),
    ]

    static func report(complete: Bool = true) -> BlitzTreeReport {
        let total = children.reduce(UInt64(0)) { $0 + $1.allocatedBytes } + gigabyte
        return BlitzTreeReport(
            root: root, scanSeconds: 4.2,
            summary: .init(
                allocatedBytes: total, logicalBytes: total, fileCount: 412_380,
                directoryCount: 58_204),
            coverage: .init(
                complete: complete, errors: complete ? 0 : 3, skippedCloudDirectories: 0,
                skippedMountPoints: complete ? 0 : 1),
            report: .init(
                candidates: candidates, candidateCount: candidates.count, truncated: false,
                inventory: .init(
                    largestChildren: children,
                    largestDirectories: children.filter(\.isDirectory),
                    largestFiles: children.filter { !$0.isDirectory })))
    }
}

@MainActor
@Suite(.serialized)
struct BlitzTreePageRenderTests {
    static func capture(_ name: String, model: BlitzTreeModel) async throws {
        for variant in BlitzTreeRenderCapture.variants {
            _ = try await BlitzTreeRenderCapture.render(name, variant: variant) {
                BlitzTreePage(model: model)
            }
        }
    }

    static func heldModel() -> (BlitzTreeModel, ScanGate) {
        let gate = ScanGate()
        let model = BlitzTreeModel(
            client: BlitzTreeClient { _, progress in
                progress(184_220)
                await gate.wait()
                return BlitzTreeRenderFixture.report()
            })
        return (model, gate)
    }

    @Test func introExplainsTheMapAndOffersAFolderChoice() async throws {
        let model = BlitzTreeModel(
            client: BlitzTreeClient { _, _ in
                BlitzTreeRenderFixture.report()
            })
        #expect(model.root == nil)
        try await Self.capture("diskmap-intro", model: model)
        await model.shutdown()
    }

    @Test func scanningShowsTheFolderAndProgress() async throws {
        let (model, gate) = Self.heldModel()
        model.scan(BlitzTreeRenderFixture.root)
        while !(await gate.waiting) { await Task.yield() }
        for _ in 0..<50 where model.scannedEntries == 0 { await Task.yield() }
        #expect(model.scanning)
        try await Self.capture("diskmap-scanning", model: model)
        await gate.release()
        await model.shutdown()
    }

    @Test func resultsDrawTheMapAndListTheLargestItems() async throws {
        let model = BlitzTreeModel(
            client: BlitzTreeClient { _, _ in
                BlitzTreeRenderFixture.report(complete: false)
            })
        model.scan(BlitzTreeRenderFixture.root)
        await model.finishWork()
        #expect(model.report?.report.inventory.largestChildren.count == 9)
        try await Self.capture("diskmap-results", model: model)
        model.list = .candidates
        _ = try await BlitzTreeRenderCapture.render(
            "diskmap-results-candidates",
            variant: .init(name: "tall", width: 1100, height: 1500, zoom: 1, scheme: .light)
        ) {
            BlitzTreePage(model: model)
        }
        await model.shutdown()
    }

    @Test func failureExplainsRecovery() async throws {
        let model = BlitzTreeModel(
            client: BlitzTreeClient { _, _ in
                throw BlitzTreeError.failed("Edith does not have permission to read this folder.")
            })
        model.scan(BlitzTreeRenderFixture.root)
        await model.finishWork()
        #expect(model.error != nil)
        try await Self.capture("diskmap-failed", model: model)
        await model.shutdown()
    }

    @Test func leavingThePageKeepsTheScanRunning() async throws {
        let (model, gate) = Self.heldModel()
        model.scan(BlitzTreeRenderFixture.root)
        while !(await gate.waiting) { await Task.yield() }
        let variant = BlitzTreeRenderCapture.variants[0]
        _ = try await BlitzTreeRenderCapture.render("diskmap-leave", variant: variant) {
            BlitzTreePage(model: model)
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.scanning)
        await gate.release()
        await model.finishWork()
        #expect(model.report?.root == BlitzTreeRenderFixture.root)
        await model.shutdown()
    }
}
