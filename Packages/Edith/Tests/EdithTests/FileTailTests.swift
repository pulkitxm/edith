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

    @Test func reversedScanCrossesChunkBoundariesAndKeepsUnterminatedTail() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("log.txt")
        try "alpha\nsecond line\nlast".write(to: url, atomically: true, encoding: .utf8)
        var lines: [String] = []

        FileTail.scanLinesReversed(url, chunkBytes: 5) { data in
            lines.append(String(decoding: data, as: UTF8.self))
            return true
        }

        #expect(lines == ["last", "second line", "alpha"])
    }

    @Test func reversedScanStopsWhenVisitorFinishes() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("log.txt")
        try "one\ntwo\nthree\n".write(to: url, atomically: true, encoding: .utf8)
        var lines: [String] = []

        FileTail.scanLinesReversed(url, chunkBytes: 4) { data in
            lines.append(String(decoding: data, as: UTF8.self))
            return lines.count < 2
        }

        #expect(lines == ["three", "two"])
    }

    @Test func reversedScanDropsOversizedCompleteAndTornLines() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let completeURL = dir.appendingPathComponent("complete.txt")
        let tornURL = dir.appendingPathComponent("torn.txt")
        let oversized = String(repeating: "x", count: 10_000)
        try "before\n\(oversized)\nafter\n".write(
            to: completeURL, atomically: true, encoding: .utf8)
        try "before\n\(oversized)".write(to: tornURL, atomically: true, encoding: .utf8)

        func scan(_ url: URL) -> [String] {
            var lines: [String] = []
            FileTail.scanLinesReversed(url, chunkBytes: 31, maxLineBytes: 128) { data in
                lines.append(String(decoding: data, as: UTF8.self))
                return true
            }
            return lines
        }

        #expect(scan(completeURL) == ["after", "before"])
        #expect(scan(tornURL) == ["before"])
    }

    @Test func reversedScanCancelsWhileDiscardingANewlineFreeLine() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cancel.txt")
        try ("before\n" + String(repeating: "x", count: 10_000)).write(
            to: url, atomically: true, encoding: .utf8)
        var checks = 0
        var lines: [String] = []

        FileTail.scanLinesReversed(
            url, chunkBytes: 31, maxLineBytes: 128,
            shouldContinue: {
                checks += 1
                return checks <= 4
            }
        ) { data in
            lines.append(String(decoding: data, as: UTF8.self))
            return true
        }

        #expect(checks == 5)
        #expect(lines.isEmpty)
    }

    @Test func reversedScanChecksCancellationBeforeTheLeadingLine() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("leading.txt")
        try "single line".write(to: url, atomically: true, encoding: .utf8)
        var checks = 0
        var lines: [String] = []

        FileTail.scanLinesReversed(
            url,
            shouldContinue: {
                checks += 1
                return checks == 1
            }
        ) { data in
            lines.append(String(decoding: data, as: UTF8.self))
            return true
        }

        #expect(checks == 2)
        #expect(lines.isEmpty)
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

    @Test func refreshRequestUsesTheInjectedOperationPath() throws {
        let url = try tempLog("")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var requested = false
        let bridge = DashboardRefreshBridge(
            logURL: url, requestUsageRefresh: { requested = true })

        bridge.requestRefresh()

        #expect(requested)
    }
}
