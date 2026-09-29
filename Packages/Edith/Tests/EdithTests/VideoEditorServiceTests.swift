import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Testing
@testable import Edith

@Suite struct VideoEditorServiceTests {
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "video-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func movie(in folder: URL) async throws -> URL {
        let image = CIImage(color: CIColor(red: 0.8, green: 0.2, blue: 0.1)).cropped(
            to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let png = folder.appendingPathComponent("synthetic.png")
        try CIContext().writePNGRepresentation(
            of: image, to: png, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let generated = try await VideoStillMedia.create(from: png, duration: 1)
        let movie = folder.appendingPathComponent("synthetic.mov")
        try FileManager.default.moveItem(at: generated, to: movie)
        return movie
    }

    @Test func strictPlanRejectsUnknownFieldsAndOperations() throws {
        for source in [
            #"{"version":1,"operations":[],"extra":true}"#,
            #"{"version":1,"operations":[{"rename":{"title":"a","typo":1}}]}"#,
            #"{"version":1,"operations":[{"unsupported":{}}]}"#,
            #"{"version":1,"operations":[{"trim":{"clipID":"a","start":0}}]}"#,
        ] {
            #expect(throws: (any Error).self) { try VideoEditPlan.decode(Data(source.utf8)) }
        }
        let plan = VideoEditPlan(operations: [.rename(title: "Synthetic project")])
        let decoded = try VideoEditPlan.decode(JSONEncoder().encode(plan))
        #expect(decoded.operations.count == 1)
        let schema = try #require(
            try JSONSerialization.jsonObject(with: VideoEditPlan.schema()) as? [String: Any])
        #expect(schema["additionalProperties"] as? Bool == false)
    }

    @Test func invalidAndDryRunPlansLeaveProjectBytesUntouched() async throws {
        let directory = try Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await Self.movie(in: directory)
        let url = directory.appendingPathComponent("project.openscreen")
        _ = try VideoEditorService.create(at: url, title: "Original")
        let before = try Data(contentsOf: url)
        let plan = VideoEditPlan(operations: [
            .addMedia(path: source.path, name: "intro"), .rename(title: "Changed"),
        ])
        let preview = try await VideoEditorService.apply(plan, to: url, dryRun: true)
        #expect(!preview.written)
        #expect(preview.aliases["intro"] != nil)
        #expect(try Data(contentsOf: url) == before)
        let invalid: [VideoEditPlan.Operation] = [
            .trim(clipID: "intro", start: 0, end: 2),
            .split(clipID: "intro", sourceTime: 0.99, rightName: "right"),
            .speed(clipID: "intro", rate: .infinity),
            .sourceAudio(clipID: "intro", gainDb: 50, muted: false),
            .reorder(clipIDs: ["intro", "intro"]),
            .crop(clipID: "intro", x: 0.9, y: 0, width: 0.5, height: 1),
            .text(content: "hello", start: 0, end: 5),
            .transition(clipID: "intro", kind: "fade", duration: 1),
            .remove(clipID: "missing"),
        ]
        for operation in invalid {
            do {
                _ = try await VideoEditorService.apply(
                    VideoEditPlan(operations: plan.operations + [operation]), to: url,
                    overwrite: true)
                Issue.record("Invalid operation unexpectedly succeeded")
            } catch {}
            #expect(try Data(contentsOf: url) == before)
        }
        do {
            _ = try await VideoEditorService.apply(
                VideoEditPlan(version: 2, operations: []), to: url, overwrite: true)
            Issue.record("Unsupported version unexpectedly succeeded")
        } catch {}
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func mutationsPersistAndNativeFramesMatchExport() async throws {
        let directory = try Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await Self.movie(in: directory)
        let original = try Data(contentsOf: source)
        let url = directory.appendingPathComponent("project.openscreen")
        _ = try VideoEditorService.create(at: url, title: "Synthetic")
        let plan = VideoEditPlan(operations: [
            .addMedia(path: "synthetic.mov", name: "intro"),
            .split(clipID: "intro", sourceTime: 0.5, rightName: "outro"),
            .trim(clipID: "intro", start: 0.1, end: 0.5),
            .speed(clipID: "intro", rate: 2),
            .sourceAudio(clipID: "intro", gainDb: -6, muted: true),
            .crop(clipID: "intro", x: 0.1, y: 0.1, width: 0.8, height: 0.8),
            .reorder(clipIDs: ["outro", "intro"]),
            .transition(clipID: "intro", kind: "fade", duration: 0.2),
            .canvas(aspectRatio: "1:1", padding: 10, backgroundColor: "#0000ff"),
            .text(content: "Demo", start: 0.1, end: 0.4),
        ])
        let applied = try await VideoEditorService.apply(plan, to: url, overwrite: true)
        let project = try VideoProject.open(url)
        #expect(project.clips.map(\.id) == [applied.aliases["outro"]!, applied.aliases["intro"]!])
        #expect(project.clips.last?.rate == 2)
        #expect(project.clips.last?.crop?["width"] == 0.8)
        #expect(project.clips.last?.raw["audioMuted"] as? Bool == true)
        #expect(project.annotations.count == 1)
        #expect(project.transitions.count == 1)
        let pipeline = try await VideoRenderPipeline.make(project: project)
        #expect(abs(pipeline.duration - 0.7) < 0.01)
        let png = directory.appendingPathComponent("frame.png")
        let mp4 = directory.appendingPathComponent("render.mp4")
        _ = try await VideoEditorService.frame(url, at: 0.05, to: png)
        _ = try await VideoEditorService.render(url, to: mp4)
        let exported = AVURLAsset(url: mp4)
        #expect(abs(try await exported.load(.duration).seconds - 0.7) < 0.05)
        let image = try #require(CGImageSourceCreateWithURL(png as CFURL, nil))
        let bitmap = try #require(CGImageSourceCreateImageAtIndex(image, 0, nil))
        #expect(
            bitmap.width == Int(pipeline.canvas.width)
                && bitmap.height == Int(pipeline.canvas.height))
        let generator = AVAssetImageGenerator(asset: exported)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let rendered = try await generator.image(at: CMTime(seconds: 0.05, preferredTimescale: 600))
            .image
        let context = CIContext()
        func pixel(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            context.render(
                CIImage(cgImage: image), toBitmap: &bytes, rowBytes: 4,
                bounds: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1),
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB())
            return bytes
        }
        let previewPixel = pixel(bitmap)
        let exportPixel = pixel(rendered)
        #expect(previewPixel[0] > 180 && previewPixel[1] < 90 && previewPixel[2] < 60)
        #expect(
            zip(previewPixel, exportPixel).allSatisfy { abs(Int($0) - Int($1)) < 24 },
            "Preview \(previewPixel), export \(exportPixel)")
        #expect(try Data(contentsOf: source) == original)
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [.remove(clipID: applied.aliases["intro"]!)]), to: url,
            overwrite: true)
        #expect(try VideoProject.open(url).clips.count == 1)
    }

    @Test func overwriteAndSourceProtectionPreserveFiles() async throws {
        let directory = try Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await Self.movie(in: directory)
        let url = directory.appendingPathComponent("project.openscreen")
        _ = try VideoEditorService.create(at: url, title: "Original")
        #expect(throws: (any Error).self) {
            try VideoEditorService.create(at: url, title: "Replacement")
        }
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [.addMedia(path: source.path, name: "clip")]), to: url,
            overwrite: true)
        let output = directory.appendingPathComponent("existing.mp4")
        let sentinel = Data("keep existing output".utf8)
        try sentinel.write(to: output)
        do {
            _ = try await VideoEditorService.render(url, to: output)
            Issue.record("Overwrite unexpectedly allowed")
        } catch {}
        #expect(try Data(contentsOf: output) == sentinel)
        let linked = directory.appendingPathComponent("linked.mp4")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: source)
        do {
            _ = try await VideoEditorService.render(url, to: linked, overwrite: true)
            Issue.record("Source symlink unexpectedly allowed")
        } catch {}
        let png = directory.appendingPathComponent("invalid.png")
        try sentinel.write(to: png)
        do {
            _ = try await VideoEditorService.frame(url, at: -1, to: png, overwrite: true)
            Issue.record("Invalid frame time unexpectedly allowed")
        } catch {}
        #expect(try Data(contentsOf: png) == sentinel)
    }

    @Test func audioGroupsApplyGainMuteAndRemoval() async throws {
        let directory = try Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await Self.movie(in: directory)
        let audioURL = directory.appendingPathComponent("tone.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100))
        buffer.frameLength = 44100
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<44100 {
            samples[index] = Float(sin(2 * Double.pi * 440 * Double(index) / 44100)) * 0.1
        }
        try AVAudioFile(forWriting: audioURL, settings: format.settings).write(from: buffer)
        let url = directory.appendingPathComponent("project.openscreen")
        _ = try VideoEditorService.create(at: url, title: "Audio demo")
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [
                .addMedia(path: source.path, name: "intro"),
                .split(clipID: "intro", sourceTime: 0.5, rightName: "outro"),
                .addAudio(path: audioURL.path, start: 0.1, offset: 0.2),
            ]), to: url, overwrite: true)
        let project = try VideoProject.open(url)
        let id = try #require(project.audioTracks.first?.id)
        #expect(project.audioTracks.count == 2)
        let pipeline = try await VideoRenderPipeline.make(project: project)
        #expect(pipeline.audioMix?.inputParameters.count == 2)
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [
                .audioOptions(trackID: id, gainDb: -9, muted: true, loop: true)
            ]), to: url, overwrite: true)
        let muted = try VideoProject.open(url)
        #expect(muted.audioTracks.allSatisfy { $0.gainDb == -9 && $0.muted && $0.loop })
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [.removeAudio(trackID: id)]), to: url, overwrite: true)
        #expect(try VideoProject.open(url).audioTracks.isEmpty)
    }

    @Test func unsafeImportedValuesAreRejectedBeforeRendering() throws {
        let directory = try Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("invalid.openscreen")
        for value in [1e300, ["nested": 1e300]] as [Any] {
            var project = VideoProject.create()
            project.root["untrusted"] = value
            try project.save(to: url)
            #expect(throws: (any Error).self) { try VideoEditorService.show(url) }
        }
        var project = VideoProject.create()
        project.aspectRatio = "1e300:1"
        try project.save(to: url)
        #expect(throws: (any Error).self) { try VideoEditorService.show(url) }
        project = VideoProject.create()
        project.root["assets"] = "not an array"
        try project.save(to: url)
        #expect(throws: (any Error).self) { try VideoEditorService.show(url) }
    }
}
