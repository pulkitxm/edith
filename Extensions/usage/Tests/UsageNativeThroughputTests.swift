import Darwin
import Foundation
import Testing

@testable import UsageExtension

@Suite(.serialized) struct UsageNativeThroughputTests {
    private func cpuSeconds() -> Double {
        var usage = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &usage)
        return Double(usage.tv_sec) + Double(usage.tv_nsec) / 1e9
    }

    @Test func bulkToolOutputTranscriptIndexesWithinCpuBudget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "usage-throughput-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let blob = String(repeating: "x", count: 40_000)
        let bulk =
            #"{"type":"user","timestamp":"2026-09-01T00:00:00.000Z","message":{"role":"user","content":[{"type":"tool_result","content":""#
            + blob + #""}]}}"# + "\n"
        let usage =
            #"{"type":"assistant","timestamp":"2026-09-01T00:00:01.000Z","requestId":"r","message":{"id":"m","model":"claude-sonnet-4-5","usage":{"input_tokens":10,"output_tokens":5}}}"#
            + "\n"
        var text = ""
        for index in 0..<1200 {
            text += bulk
            if index % 40 == 0 {
                text += usage.replacingOccurrences(of: "\"m\"", with: "\"m\(index)\"")
            }
        }
        try text.write(to: file, atomically: true, encoding: .utf8)
        let parser = UsageNativeParser(source: "cli")
        let started = cpuSeconds()
        let snapshot = try parser.snapshot(file, key: "k", previous: nil)
        let spent = cpuSeconds() - started
        #expect(snapshot.records.count == 30)
        #expect(snapshot.size == text.utf8.count)
        #expect(spent < 0.25, "indexing 48 MB took \(spent) s of cpu")
    }

    @Test func lineSplittingKeepsOffsetsAcrossReadChunks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "usage-lines-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("lines.jsonl")
        let lengths = [10, 300_000, 5, 262_143, 262_144, 70_000, 1]
        let lines = lengths.map { String(repeating: "a", count: $0) }
        try (lines.joined(separator: "\n") + "\n").write(
            to: file, atomically: true, encoding: .utf8)
        var seen: [(Int, Int, Int)] = []
        let result = try UsageNativeFileIO.lines(file) { data, offset, end in
            seen.append((data.count, offset, end))
        }
        var cursor = 0
        for (index, length) in lengths.enumerated() {
            #expect(seen[index].0 == length)
            #expect(seen[index].1 == cursor)
            cursor += length + 1
            #expect(seen[index].2 == cursor)
        }
        #expect(seen.count == lengths.count)
        #expect(result.0 == cursor)
        #expect(result.1 == cursor)
    }
}
