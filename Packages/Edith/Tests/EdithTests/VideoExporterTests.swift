import Foundation
import Testing
@testable import Edith

@MainActor
@Suite struct VideoExporterTests {
    private let destination = URL(fileURLWithPath: "/tmp/edith-export-test.mp4")

    @Test func reportsProgressThenFinishes() async {
        var completions: [VideoExporter.Phase?] = []
        let exporter = VideoExporter { completions.append($0?.phase) }
        let gate = AsyncStream<Void>.makeStream()
        exporter.start(to: destination) { progress in
            progress(0.4)
            for await _ in gate.stream { break }
        }
        await waitUntil { exporter.job?.progress == 0.4 }
        #expect(exporter.isExporting)
        #expect(exporter.job?.destination == destination)
        exporter.start(to: URL(fileURLWithPath: "/tmp/other.mp4")) { _ in }
        #expect(exporter.job?.destination == destination)
        gate.continuation.yield()
        await waitUntil { exporter.job?.phase == .finished }
        #expect(exporter.job?.progress == 1)
        #expect(completions == [.finished])
        exporter.clear()
        #expect(exporter.job == nil)
    }

    @Test func stoppingAnExportClearsIt() async {
        var completions: [VideoExporter.Phase?] = []
        let exporter = VideoExporter { completions.append($0?.phase) }
        exporter.start(to: destination) { _ in
            try await Task.sleep(for: .seconds(30))
        }
        #expect(exporter.isExporting)
        exporter.clear()
        #expect(exporter.isExporting)
        exporter.cancel()
        await waitUntil { exporter.job == nil }
        #expect(exporter.job == nil)
        #expect(completions == [nil])
    }

    @Test func failureKeepsTheMessage() async {
        let exporter = VideoExporter()
        exporter.start(to: destination) { _ in
            throw VideoRenderPipeline.RenderError.exportFailed("Disk full")
        }
        await waitUntil { exporter.job?.phase != .exporting }
        #expect(exporter.job?.phase == .failed("Disk full"))
        #expect(!exporter.isExporting)
    }

    @Test func remainingTimeReadsNaturally() {
        #expect(VideoExportSheet.remaining(95) == "2 minutes")
        #expect(VideoExportSheet.remaining(12) == "12 seconds")
        #expect(VideoExportSheet.remaining(0.2) == "1 second")
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
