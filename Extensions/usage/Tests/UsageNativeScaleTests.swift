import Darwin
import Foundation
import Testing

@testable import UsageExtension

@Suite(.serialized) struct UsageNativeScaleTests {
    private static let files = 24
    private static let records = 5000
    private static let uniquePerFile = 4901

    private func generate(into home: URL) throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/generate-usage-corpus.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            script.path, home.path, "--files", String(Self.files), "--records",
            String(Self.records),
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func largeCorpusIndexesWithBoundedMemoryAndReindexesNothingWhenUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "usage-scale-" + UUID().uuidString)
        let home = root.appendingPathComponent("home")
        let data = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try generate(into: home)
        let environment = ["EDITH_USAGE_OFFLINE": "1", "TZ": "UTC"]
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let baseline = currentFootprint()
        let peak = PeakSampler(read: currentFootprint)
        let first = try await UsageNativeCollector.collect(
            home: home, dataDirectory: data, environment: environment, now: now,
            network: UsageNativeNetwork(), onEvent: { _ in })
        let growth = peak.stop() - baseline
        #expect(growth < 150 * 1_048_576, "peak footprint grew \(growth / 1_048_576) MB")
        let document = try UsageNativeJSON.object(first)
        let totals = try #require(document["totals"] as? [String: Any])
        #expect((totals["tokens"] as? Double ?? 0) > 0)
        let archive = try UsageNativeArchive(dataDirectory: data)
        var held = 0
        try archive.forEachEffectiveEvent { _, _ in held += 1 }
        #expect(held == Self.files * Self.uniquePerFile)

        let journals = SummaryBox()
        let second = try await UsageNativeCollector.collect(
            home: home, dataDirectory: data, environment: environment,
            now: now.addingTimeInterval(60), network: UsageNativeNetwork(),
            onEvent: {
                if case .summary(let label, let value) = $0, label == "journals" {
                    journals.set(value)
                }
            })
        #expect(journals.value == "0")
        let reread = try UsageNativeJSON.object(second)
        #expect(
            (reread["totals"] as? [String: Any])?["tokens"] as? Double == totals["tokens"]
                as? Double)
    }
}

private func currentFootprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

private final class SummaryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? { lock.withLock { stored } }
    func set(_ value: String) { lock.withLock { stored = value } }
}

private final class PeakSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak = 0
    private var running = true
    private let read: @Sendable () -> Int

    init(read: @escaping @Sendable () -> Int) {
        self.read = read
        let thread = Thread { [self] in
            while lock.withLock({ running }) {
                let value = self.read()
                lock.withLock { peak = max(peak, value) }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        thread.start()
    }

    func stop() -> Int {
        lock.withLock {
            running = false; return peak
        }
    }
}
