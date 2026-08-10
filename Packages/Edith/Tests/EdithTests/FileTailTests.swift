import EdithKit
import Foundation
import Testing

@Suite struct FileTailTests {
    private func tempDir() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-tail-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test func smallFileReturnsFullContent() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("log.txt")
        let content = "alpha\nbeta\ngamma\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
        #expect(FileTail.read(url, maxBytes: 1024) == content)
    }

    @Test func largeFileDropsPartialLeadingLine() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("log.txt")
        let content = "0123456789\n0123456789\n0123456789\n0123456789\n0123456789\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
        #expect(FileTail.read(url, maxBytes: 25) == "0123456789\n0123456789\n")
    }

    @Test func truncationOnNewlineKeepsFollowingCompleteLines() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("log.txt")
        try "aaa\nbbb\nccc\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(FileTail.read(url, maxBytes: 9) == "bbb\nccc\n")
    }

    @Test func emptyFileReturnsEmptyString() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("log.txt")
        try Data().write(to: url)
        #expect(FileTail.read(url, maxBytes: 1024) == "")
    }

    @Test func missingFileReturnsEmptyString() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("absent.txt")
        #expect(FileTail.read(url, maxBytes: 1024) == "")
    }
}

@Suite @MainActor struct DashboardRefreshBridgeTests {
    private func tempLog(_ content: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("refresh.log")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func initLoadsLogTail() throws {
        let url = try tempLog("first line\nsecond line\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let bridge = DashboardRefreshBridge(logURL: url)
        #expect(bridge.log == "first line\nsecond line\n")
        #expect(!bridge.updating)
    }

    @Test func initTailsOversizedLogToCompleteLines() throws {
        let filler = String(repeating: "x", count: 70 * 1024)
        let url = try tempLog(filler + "\ntail line\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let bridge = DashboardRefreshBridge(logURL: url)
        #expect(bridge.log == "tail line\n")
    }
}
