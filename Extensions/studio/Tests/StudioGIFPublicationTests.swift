import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import StudioExtension

private final class StudioExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Error>?
    private(set) var rendered = false
    func attach(_ task: Task<Void, Error>) { lock.lock(); self.task = task; lock.unlock() }
    func cancelAfterFrame(_ fraction: Double) {
        guard fraction > 0, fraction < 1 else { return }
        lock.lock(); rendered = true; let owned = task; lock.unlock()
        owned?.cancel()
    }
}

@MainActor @Suite(.serialized) struct StudioGIFPublicationTests {
    @Test func cancelledGIFAfterActualFrameRetainsExistingOutputAndSource() async throws {
        let root = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = try await VideoEditorServiceTests.movie(in: root)
        let original = try Data(contentsOf: movie)
        var project = VideoProject.create()
        project.addAsset(movie, duration: 1, width: 64, height: 64)
        let clip = try #require(project.clips.first?.id)
        for _ in 0..<9 { _ = project.duplicate(clipID: clip) }
        let pipeline = try await VideoRenderPipeline.make(project: project)
        let output = root.appendingPathComponent("preserved.gif")
        let previous = Data("Synthetic previous GIF output".utf8)
        try previous.write(to: output)
        let cancellation = StudioExportCancellation()
        let task = Task {
            try await pipeline.exportGIF(
                to: output, progress: { cancellation.cancelAfterFrame($0) })
        }
        cancellation.attach(task)
        let start = ContinuousClock.now
        do {
            try await task.value; Issue.record("Cancelled GIF export completed.")
        } catch is CancellationError {}
        #expect(cancellation.rendered && start.duration(to: .now) < .seconds(5))
        #expect(try Data(contentsOf: output) == previous && Data(contentsOf: movie) == original)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy {
                !$0.hasPrefix(".studio-video-")
            })
    }

    @Test func originalGIFExportProducesRequestedFramesWidthAndLoopMetadata() async throws {
        let root = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = try await VideoEditorServiceTests.movie(in: root)
        var project = VideoProject.create()
        project.addAsset(movie, duration: 1, width: 64, height: 64)
        let pipeline = try await VideoRenderPipeline.make(project: project)
        let output = root.appendingPathComponent("encoded.gif")
        try await pipeline.exportGIF(to: output, fps: 7, maxWidth: 32, loop: true)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 7)
        let frame = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(
            frame.width == 32
                && frame.height
                    == Int((32 * pipeline.canvas.height / pipeline.canvas.width).rounded())
        )
        let properties = try #require(CGImageSourceCopyProperties(source, nil) as? [String: Any])
        let gif = try #require(
            properties[kCGImagePropertyGIFDictionary as String] as? [String: Any])
        #expect(gif[kCGImagePropertyGIFLoopCount as String] as? Int == 0)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy {
                !$0.hasPrefix(".studio-video-")
            })
    }
}
