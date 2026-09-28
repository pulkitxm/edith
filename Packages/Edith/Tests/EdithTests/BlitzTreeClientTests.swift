import Darwin
import Foundation
import Testing

@testable import EdithKit

@Suite struct BlitzTreeClientTests {
    static func report(root: String) -> BlitzTreeReport {
        .init(
            root: root, scanSeconds: 0.1,
            summary: .init(allocatedBytes: 0, logicalBytes: 0, fileCount: 0, directoryCount: 1),
            coverage: .init(
                complete: true, errors: 0, skippedCloudDirectories: 0, skippedMountPoints: 0),
            report: .init(
                candidates: [], candidateCount: 0, truncated: false,
                inventory: .init(largestChildren: [], largestDirectories: [], largestFiles: [])))
    }

    @Test func invalidRootsNeverLaunch() async {
        let client = BlitzTreeClient { _, _ in
            Issue.record("Invalid roots must not launch a scan")
            return Self.report(root: "/fixtures")
        }
        for root in ["", "relative", "/fixtures\0bad"] {
            await #expect(throws: BlitzTreeError.invalidRoot) { try await client.scan(root: root) }
        }
    }

    @Test func nativeScannerCountsHardLinksOnceAndDoesNotFollowDirectoryLinks() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("quotes '; $(example).bin")
        let content = Data(repeating: 42, count: 8192)
        try content.write(to: file)
        try FileManager.default.linkItem(at: file, to: root.appendingPathComponent("hardlink"))
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("loop").path, withDestinationPath: root.path)
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("broken").path,
            withDestinationPath: "/missing-blitztree-fixture")
        let report = try await BlitzTreeClient.live.scan(root: root.path)
        #expect(report.coverage.complete)
        #expect(report.summary.fileCount == 4)
        #expect(report.summary.directoryCount == 1)
        #expect(report.report.inventory.largestChildren.count == 4)
        #expect(
            report.report.inventory.largestChildren.filter {
                $0.name == "hardlink" || $0.name == file.lastPathComponent
            }.reduce(0) { $0 + $1.logicalBytes } == 8192)
        #expect(try Data(contentsOf: file) == content)
        var metadata = stat()
        #expect(lstat(file.path, &metadata) == 0)
        let counted = report.report.inventory.largestChildren.filter { $0.inode == metadata.st_ino }
        #expect(counted.reduce(0) { $0 + $1.allocatedBytes } == UInt64(metadata.st_blocks) * 512)
    }

    @Test func nestedCandidatesAreDeduplicatedAndReportsAreBounded() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for path in [
            "a/node_modules/nested/node_modules", "b/node_modules", ".Trash/node_modules", "target",
            "valid/target",
        ] {
            let directory = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try Data(repeating: 7, count: 8192).write(
                to: directory.appendingPathComponent("fixture.bin"))
        }
        try Data().write(to: root.appendingPathComponent("valid/Cargo.toml"))
        let report = try BlitzTreeScanner.scan(root: root.path, minimumBytes: 1, limit: 2)
        #expect(report.coverage.complete)
        #expect(report.report.candidateCount == 3)
        #expect(report.report.truncated)
        #expect(report.report.candidates.count == 2)
        #expect(report.report.inventory.largestChildren.count == 2)
        #expect(report.report.inventory.largestDirectories.count == 2)
        #expect(report.report.inventory.largestFiles.count == 2)
        #expect(
            report.report.candidates.allSatisfy {
                !$0.path.contains("nested") && !$0.path.contains(".Trash")
            })
        let full = try BlitzTreeScanner.scan(root: root.path, minimumBytes: 1)
        #expect(full.report.candidates.contains { $0.path.hasSuffix("valid/target") })
        #expect(
            !full.report.candidates.contains {
                $0.path == root.appendingPathComponent("target").path
            })
    }

    @Test func sparseFilesUseAllocatedRatherThanLogicalBytes() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sparse.bin")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 100_000_000)
        try handle.close()
        let report = try BlitzTreeScanner.scan(root: root.path, minimumBytes: 0)
        let entry = try #require(report.report.inventory.largestChildren.first)
        #expect(entry.logicalBytes == 100_000_000)
        #expect(entry.allocatedBytes < entry.logicalBytes)
    }

    @Test func unreadableDirectoriesReportPartialCoverage() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try Data([1]).write(to: blocked.appendingPathComponent("hidden.bin"))
        #expect(chmod(blocked.path, 0) == 0)
        defer { chmod(blocked.path, 0o700) }
        let report = try BlitzTreeScanner.scan(root: root.path)
        #expect(!report.coverage.complete)
        #expect(report.coverage.errors > 0)
    }

    @Test func emptyFoldersSymlinkRootsAndCancellation() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("empty")
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "empty")
        let report = try BlitzTreeScanner.scan(root: link.path)
        #expect(report.root == (try BlitzTreeScanner.resolvedDirectory(folder.path)))
        #expect(report.summary.fileCount == 0)
        #expect(report.coverage.complete)
        #expect(report.report.inventory.largestChildren.isEmpty)
        #expect(throws: CancellationError.self) {
            try BlitzTreeScanner.scan(root: root.path, isCancelled: { true })
        }
        #expect(throws: (any Error).self) {
            try BlitzTreeScanner.scan(root: root.appendingPathComponent("missing").path)
        }
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("blitztree-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
