@testable import HerdrUI
import EdithExtensionSupport
import EdithExtensionUI
import Darwin
import Foundation
import Testing

@Suite struct AgentTranscriptMemoryTests {
    private final class Peak: @unchecked Sendable {
        private let lock = NSLock()
        private var maximum = 0.0
        private var running = true

        func record(_ value: Double) { lock.withLock { maximum = max(maximum, value) } }
        var value: Double { lock.withLock { maximum } }
        var isRunning: Bool { lock.withLock { running } }
        func stop() { lock.withLock { running = false } }
    }

    private static func footprintMegabytes() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    private func writeTranscript(to url: URL, megabytes: Int) throws -> UInt64 {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let text = String(repeating: "synthetic transcript text ", count: 80)
        let assistant =
            #"{"type":"assistant","timestamp":"2026-01-01T00:00:00.000Z","message":{"content":[{"type":"text","text":"\#(text)"}]}}"#
        let user =
            #"{"type":"user","timestamp":"2026-01-01T00:00:01.000Z","cwd":"/tmp/synthetic","message":{"content":"\#(text)"}}"#
        let batch = Data(
            ((0..<2_000).map { $0.isMultiple(of: 2) ? user : assistant }
                .joined(separator: "\n") + "\n").utf8)
        var written = 0
        while written < megabytes << 20 {
            try handle.write(contentsOf: batch)
            written += batch.count
        }
        return UInt64(written)
    }

    @Test func digestingALargeTranscriptDoesNotBalloonMemory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "transcript-memory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let size = try writeTranscript(to: file, megabytes: 64)

        let baseline = Self.footprintMegabytes()
        let peak = Peak()
        let sampler = Thread {
            while peak.isRunning {
                peak.record(Self.footprintMegabytes())
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        sampler.start()
        var digest = AgentTranscriptDigest(path: file.path, kind: .claude)
        let finished = try AgentTranscriptReader.update(&digest, url: file)
        peak.stop()

        #expect(finished)
        #expect(digest.offset == size)
        #expect(!digest.prompts.isEmpty && !digest.replies.isEmpty)
        let growth = peak.value - baseline
        #expect(growth < 40, "digesting \(size >> 20) MB grew the footprint by \(Int(growth)) MB")
    }
}
