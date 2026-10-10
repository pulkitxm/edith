import Darwin
import Foundation
import Testing
@testable import UsageExtension

@Suite(.serialized) struct UsageNativeStorageTests {
    @Test func canonicalEventsRetainOnlyUsageMetadata() throws {
        let event = UsageNativeEvent(
            source: "cli", identity: "mock-message", session: "mock-session", model: "mock-model",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000), cwd: "/mock/project", title: nil,
            tokens: .init(input: 10, output: 3), recordedCost: 1.5)
        let data = try event.canonicalData
        #expect(try JSONDecoder().decode(UsageNativeEvent.self, from: data) == event)
        #expect(String(decoding: data, as: UTF8.self).contains("mock-message"))
        #expect(!String(decoding: data, as: UTF8.self).contains("content"))
    }

    @Test func tokenCountsRejectBooleanNegativeFractionAndUnsafeInteger() throws {
        for value: Any in [true, -1, 0.5, 9_007_199_254_740_992.0, "10", NSNull()] {
            #expect(throws: UsageNativeFailure.self) { try UsageNativeTokens.number(value) }
        }
        #expect(try UsageNativeTokens.number(42) == 42)
        #expect(try UsageNativeTokens.number(nil) == 0)
    }

    @Test func openAICachedAndWrittenTokensAreExcludedFromFreshInput() throws {
        let tokens = try UsageNativeTokens.openAI([
            "input_tokens": 100, "cached_input_tokens": 60, "cache_write_input_tokens": 10,
            "output_tokens": 7, "reasoning_output_tokens": 3,
        ])
        #expect(tokens == .init(input: 30, output: 7, creation: 10, read: 60))
        #expect(tokens.total == 107)
        #expect(throws: UsageNativeFailure.self) {
            try UsageNativeTokens.openAI(["input_tokens": 5, "cached_input_tokens": 10])
        }
    }

    @Test func anthropicCachesUseTheLargerCompleteBreakdownAndKeepHourCounts() throws {
        let tokens = try UsageNativeTokens.anthropic([
            "input_tokens": 2, "output_tokens": 3, "cache_creation_input_tokens": 4,
            "cache_read_input_tokens": 7,
            "cache_creation": ["ephemeral_5m_input_tokens": 5, "ephemeral_1h_input_tokens": 6],
        ])
        #expect(tokens == .init(input: 2, output: 3, creation: 11, read: 7, creationHour: 6))
    }

    @Test func projectedFileScanPreservesByteOffsetsAndPartialTrailingReceipts() throws {
        try fixture { root in
            let path = root.appendingPathComponent("events.jsonl")
            try Data("{\"id\":1}\n{\"id\":2}".utf8).write(to: path)
            var offsets: [Int] = []
            let first = try UsageNativeFileIO.lines(path) { _, offset, _ in offsets.append(offset) }
            #expect(offsets == [0, 9]); #expect(first.1 == first.0)
            let prefix = first.3
            try Data("{\"id\":1}\n{\"id\":2}\n{\"id\":".utf8).write(to: path)
            let second = try UsageNativeFileIO.lines(path, previousBytes: first.0) { _, _, _ in }
            #expect(second.4 == prefix); #expect(second.1 < second.0)
        }
    }

    @Test func sourceScanRejectsSymlinksFifosAndAdmissionOverflows() throws {
        try fixture { root in
            let target = root.appendingPathComponent("target.json")
            try Data("{}".utf8).write(to: target)
            let link = root.appendingPathComponent("linked.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            #expect(throws: UsageNativeFailure.self) { try UsageNativeFileIO.read(link) }
            #expect(
                try UsageNativeFileIO.files(under: root, extensions: ["json"]).map(
                    \.lastPathComponent) == ["target.json"])
            let fifo = root.appendingPathComponent("pipe.json")
            #expect(mkfifo(fifo.path, 0o600) == 0)
            #expect(throws: UsageNativeFailure.self) { try UsageNativeFileIO.read(fifo) }
            #expect(throws: UsageNativeFailure.self) {
                try UsageNativeFileIO.read(target, maximum: 1)
            }
            var limits = UsageNativeFileLimits(); limits.lineBytes = 1
            #expect(throws: UsageNativeFailure.self) {
                try UsageNativeFileIO.lines(target, limits: limits) { _, _, _ in }
            }
        }
    }

    @Test func changedFileDuringReadIsRejectedBeforeArchiveAdmission() throws {
        try fixture { root in
            let path = root.appendingPathComponent("changed.jsonl")
            try Data("{}\n".utf8).write(to: path)
            #expect(throws: UsageNativeFailure.self) {
                try UsageNativeFileIO.lines(path) { _, _, _ in
                    try Data("{\"changed\":true}\n".utf8).write(to: path)
                }
            }
        }
    }

    @Test func archiveTransactionsRollBackAndPrivateDatabaseRejectsSymlinks() throws {
        try fixture { root in
            let path = root.appendingPathComponent("records.sqlite")
            let db = try UsageNativeDatabase(url: path)
            try db.execute("CREATE TABLE records(id TEXT PRIMARY KEY,value REAL NOT NULL)")
            #expect(throws: UsageNativeFailure.self) {
                try db.transaction {
                    try db.run("INSERT INTO records VALUES(?,?)", ["mock", 1.5])
                    throw UsageNativeFailure.capacity
                }
            }
            #expect(try db.rows("SELECT * FROM records").isEmpty)
            try db.run("INSERT INTO records VALUES(?,?)", ["mock", 1.5])
            #expect(try db.rows("SELECT * FROM records").first?["value"] == "1.5")
            db.close()
            let link = root.appendingPathComponent("linked.sqlite")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
            #expect(throws: UsageNativeFailure.self) { try UsageNativeDatabase(url: link) }
            #expect(
                try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions]
                    as? Int == 0o600)
        }
    }

    @Test func cancelledTasksStopFileScansAndSQLiteReads() async throws {
        let task = Task {
            try await Task.sleep(for: .milliseconds(20))
            try UsageNativeFileIO.files(
                under: URL(fileURLWithPath: "/missing/mock"), extensions: ["json"])
        }
        task.cancel()
        do {
            _ = try await task.value; Issue.record("Cancelled scan continued")
        } catch is CancellationError {}
    }

    private func fixture(_ action: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "usage-native-" + UUID().uuidString)
        try UsageNativeFileIO.privateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        try action(root)
    }
}
