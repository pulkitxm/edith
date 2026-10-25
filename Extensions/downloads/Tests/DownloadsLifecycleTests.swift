import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Testing

@testable import DownloadsExtension

extension DownloadsExtensionTests {
    @Suite struct LifecycleTests {
        @Test func stoppingTheQueueCancelsAndAwaitsOwnedEstimates() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "download-estimate-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let gate = EstimateGate()
            let queue = DownloadWorker(
                file: root.appendingPathComponent("queue.json"),
                executable: { URL(fileURLWithPath: "/fixture/yt-dlp") },
                runCommand: { _, _ in try await gate.run() })
            let pending = Task {
                try await queue.estimate(URL(string: "https://example.test/video")!)
            }
            for _ in 0..<100 {
                if await gate.started { break }; try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await gate.started)
            let clock = ContinuousClock.now
            await queue.stop()
            #expect(clock.duration(to: .now) < .seconds(2))
            #expect(await gate.cancelled)
            await #expect(throws: CancellationError.self) { _ = try await pending.value }
            await #expect(throws: DownloadsError.self) {
                _ = try await queue.estimate(URL(string: "https://example.test/video")!)
            }
        }
    }
}

private actor EstimateGate {
    private(set) var started = false
    private(set) var cancelled = false
    func run() async throws -> CLICommandResult {
        started = true
        do { try await Task.sleep(for: .seconds(600)) } catch {
            cancelled = true
            throw error
        }
        throw CancellationError()
    }
}
