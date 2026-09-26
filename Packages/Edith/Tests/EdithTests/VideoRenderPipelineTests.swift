import AVFoundation
import AppKit
import CoreVideo
import ImageIO
import os
import Testing
@testable import Edith

@Suite struct VideoRenderPipelineTests {
    @Test func transitionFadesAtClipBoundaryInPreviewAndExport() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-transition-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("bright.mov")
        try await createVideo(at: source, brightness: 200)
        var project = VideoProject.create()
        project.addAsset(source, duration: 1, width: 64, height: 64)
        let firstID = try #require(project.clips.first?.id)
        let secondID = project.duplicate(clipID: firstID)
        let second = try #require(secondID)
        project.setTransition(before: second, kind: "fade", duration: 0.6)
        let pipeline = try await VideoRenderPipeline.make(project: project)
        #expect(abs(pipeline.duration - 2) < 0.02)
        let generator = AVAssetImageGenerator(asset: pipeline.composition)
        generator.videoComposition = pipeline.videoComposition
        func brightness(at seconds: Double) throws -> CGFloat {
            let frame = try generator.copyCGImage(
                at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
            return try #require(
                NSBitmapImageRep(cgImage: frame).colorAt(x: 32, y: 32)?
                    .usingColorSpace(.deviceRGB)
            ).redComponent
        }
        let normal = try brightness(at: 0.5)
        let faded = try brightness(at: 0.95)
        #expect(faded < normal - 0.3)
        let exported = directory.appendingPathComponent("transition.mp4")
        try await pipeline.exportMP4(to: exported)
        let output = try frame(at: 0.95, in: exported)
        let outputPixel = try #require(
            NSBitmapImageRep(cgImage: output).colorAt(x: 32, y: 32)?
                .usingColorSpace(.deviceRGB))
        #expect(outputPixel.redComponent < normal - 0.25)
    }

    @Test func sparseScreenRecordingExportsAtASteadyFrameRate() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-frame-rate-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("sparse.mov")
        try await createVideo(at: source, frameTimes: [0, 0.04, 0.6, 0.62, 0.95], length: 1)
        var project = VideoProject.create()
        project.addAsset(source, duration: 1, width: 64, height: 64)
        let pipeline = try await VideoRenderPipeline.make(project: project)
        let exported = directory.appendingPathComponent("steady.mp4")
        let reported = OSAllocatedUnfairLock(initialState: [Double]())
        try await pipeline.exportMP4(to: exported) { value in
            reported.withLock { $0.append(value) }
        }
        #expect(reported.withLock { $0.last } == 1)
        let asset = AVURLAsset(url: exported)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 {
                times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            }
        }
        times.sort()
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }
        #expect(times.count >= 58)
        #expect(gaps.allSatisfy { abs($0 - 1.0 / 60) < 0.002 })
    }

    @Test @MainActor func importedImageRendersAsEditableClip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-still-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("red.png")
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: imageURL)
        let movie = try await VideoStillMedia.create(from: imageURL, duration: 0.5)
        defer { try? FileManager.default.removeItem(at: movie) }
        var project = VideoProject.create()
        project.addAsset(
            movie, duration: 0.5, width: 64, height: 64,
            label: imageURL.lastPathComponent, sourceImage: imageURL)
        #expect(project.assets[0].label == "red.png")
        let pipeline = try await VideoRenderPipeline.make(project: project)
        let generator = AVAssetImageGenerator(asset: pipeline.composition)
        generator.videoComposition = pipeline.videoComposition
        let frame = try generator.copyCGImage(
            at: CMTime(seconds: 0.2, preferredTimescale: 600), actualTime: nil)
        let pixel = try #require(
            NSBitmapImageRep(cgImage: frame).colorAt(x: 32, y: 32)?.usingColorSpace(.deviceRGB))
        #expect(pixel.redComponent > 0.7)
        #expect(pixel.greenComponent < 0.3)
    }

    @Test func opensRealOpenScreenProjectWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["OPENSCREEN_SAMPLE_PROJECT"] else {
            return
        }
        let project = try VideoProject.open(URL(fileURLWithPath: path))
        let pipeline = try await VideoRenderPipeline.make(project: project)
        #expect(pipeline.duration > 0)
        let generator = AVAssetImageGenerator(asset: pipeline.composition)
        generator.videoComposition = pipeline.videoComposition
        let frame = try generator.copyCGImage(
            at: CMTime(seconds: min(1, pipeline.duration / 2), preferredTimescale: 600),
            actualTime: nil)
        #expect(frame.width > 0 && frame.height > 0)
    }

    @Test func exportsEditsToMP4AndGIF() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-render-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try await createVideo(at: source)

        var project = VideoProject.create(title: "Export test")
        project.addAsset(source, duration: 1, width: 64, height: 64)
        var withTrim = project
        withTrim.addTrim(clipID: withTrim.clips[0].id, start: 0.2, end: 0.6)
        let trimmed = try await VideoRenderPipeline.make(project: withTrim)
        #expect(abs(trimmed.duration - 0.6) < 0.02)
        #expect(trimmed.segments.count == 2)
        let trimmedURL = directory.appendingPathComponent("trimmed.mp4")
        try await trimmed.exportMP4(to: trimmedURL)
        let trimmedDuration = try await AVURLAsset(url: trimmedURL).load(.duration).seconds
        #expect(abs(trimmedDuration - trimmed.duration) < 0.05)
        let v2URL = directory.appendingPathComponent("legacy.openscreen")
        let v2Project: [String: Any] = [
            "version": 2, "media": ["screenVideoPath": source.path],
            "editor": [
                "wallpaper": "#171b25", "zoomRegions": [],
                "annotationRegions": [], "speedRegions": [],
            ],
        ]
        try JSONSerialization.data(withJSONObject: v2Project).write(to: v2URL)
        let migrated = await (try VideoProject.open(v2URL)).probingMissingMedia()
        #expect(abs(migrated.clips[0].duration - 1) < 0.01)
        let migratedPipeline = try await VideoRenderPipeline.make(project: migrated)
        #expect(abs(migratedPipeline.duration - 1) < 0.01)
        let baseline = try await VideoRenderPipeline.make(project: project)
        do {
            try await baseline.exportMP4(to: directory.appendingPathComponent("baseline.mp4"))
        } catch { Issue.record("Unedited MP4 export failed: \(error)"); return }
        var styled = project
        styled.addText("I", startMs: 0, endMs: 1000)
        let annotationID = try #require(styled.annotations.first?.id)
        styled.setAnnotationStyle(annotationID, key: "backgroundColor", value: "#FF0000")
        styled.setAnnotationStyle(annotationID, key: "color", value: "#00FF00")
        styled.setAnnotationPosition(annotationID, axis: "y", value: 50)
        let styledPipeline = try await VideoRenderPipeline.make(project: styled)
        let styledGenerator = AVAssetImageGenerator(asset: styledPipeline.composition)
        styledGenerator.videoComposition = styledPipeline.videoComposition
        let styledFrame = try styledGenerator.copyCGImage(
            at: CMTime(seconds: 0.3, preferredTimescale: 600), actualTime: nil)
        let styledBitmap = NSBitmapImageRep(cgImage: styledFrame)
        let plateRendered = (15..<50).contains { x in
            (15..<50).contains { y in
                guard let pixel = styledBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                else { return false }
                return pixel.redComponent > 0.8 && pixel.greenComponent < 0.2
            }
        }
        #expect(plateRendered)
        let music = directory.appendingPathComponent("music.caf")
        try createAudio(at: music)
        var withAudio = project
        withAudio.addAudio(music, duration: 1, at: 200)
        let mixed = try await VideoRenderPipeline.make(project: withAudio)
        #expect(mixed.audioMix != nil)
        withAudio.addTrim(clipID: withAudio.clips[0].id, start: 0.4, end: 0.6)
        let audioWithCut = try await VideoRenderPipeline.make(project: withAudio)
        let audioSegments = try #require(
            audioWithCut.composition.tracks(withMediaType: .audio).first?.segments
        ).filter { !$0.isEmpty }
        #expect(audioSegments.count == 2)
        #expect(abs(audioSegments[1].timeMapping.source.start.seconds - 0.4) < 0.02)
        let mixedURL = directory.appendingPathComponent("mixed.mp4")
        try await mixed.exportMP4(to: mixedURL)
        #expect(try await !AVURLAsset(url: mixedURL).loadTracks(withMediaType: .audio).isEmpty)
        var withCamera = project
        let cameraSource = directory.appendingPathComponent("camera-source.mov")
        try await createVideo(at: cameraSource, brightness: 180)
        withCamera.attachCamera(cameraSource, to: withCamera.assets[0].id)
        let cameraPipeline = try await VideoRenderPipeline.make(project: withCamera)
        let cameraMP4 = directory.appendingPathComponent("camera.mp4")
        try await cameraPipeline.exportMP4(to: cameraMP4)
        #expect(
            (try FileManager.default.attributesOfItem(atPath: cameraMP4.path)[.size]
                as? Int ?? 0) > 0)
        let baselineFrame = try frame(at: 0.3, in: directory.appendingPathComponent("baseline.mp4"))
        let cameraFrame = try frame(at: 0.3, in: cameraMP4)
        let baselinePixel = try #require(
            NSBitmapImageRep(cgImage: baselineFrame)
                .colorAt(x: 53, y: 48)?.usingColorSpace(.deviceRGB))
        let cameraPixel = try #require(
            NSBitmapImageRep(cgImage: cameraFrame)
                .colorAt(x: 53, y: 48)?.usingColorSpace(.deviceRGB))
        #expect(cameraPixel.redComponent > baselinePixel.redComponent + 0.25)
        withCamera.addCameraFullscreen(startMs: 100, endMs: 800)
        let fullscreen = try await VideoRenderPipeline.make(project: withCamera)
        let fullscreenGenerator = AVAssetImageGenerator(asset: fullscreen.composition)
        fullscreenGenerator.videoComposition = fullscreen.videoComposition
        let fullscreenFrame = try fullscreenGenerator.copyCGImage(
            at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)
        let baselineCorner = try #require(
            NSBitmapImageRep(cgImage: baselineFrame)
                .colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB))
        let fullscreenCorner = try #require(
            NSBitmapImageRep(cgImage: fullscreenFrame)
                .colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB))
        #expect(fullscreenCorner.redComponent > baselineCorner.redComponent + 0.25)
        let cursorSidecar = URL(fileURLWithPath: source.path + ".cursor.json")
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "samples": [
                [
                    "timeMs": 0, "cx": 0.5, "cy": 0.5, "visible": true,
                    "interactionType": "move",
                ],
                [
                    "timeMs": 300, "cx": 0.5, "cy": 0.5, "visible": true,
                    "interactionType": "click",
                ],
            ],
        ]).write(to: cursorSidecar)
        project.cursorHighlight = true
        let cursorPipeline = try await VideoRenderPipeline.make(project: project)
        let cursorGenerator = AVAssetImageGenerator(asset: cursorPipeline.composition)
        cursorGenerator.videoComposition = cursorPipeline.videoComposition
        let cursorFrame = try cursorGenerator.copyCGImage(
            at: CMTime(seconds: 0.3, preferredTimescale: 600), actualTime: nil)
        let cursorPixel = try #require(
            NSBitmapImageRep(cgImage: cursorFrame)
                .colorAt(x: 32, y: 32)?.usingColorSpace(.deviceRGB))
        let baseCenter = try #require(
            NSBitmapImageRep(cgImage: baselineFrame)
                .colorAt(x: 32, y: 32)?.usingColorSpace(.deviceRGB))
        #expect(cursorPixel.redComponent > baseCenter.redComponent + 0.25)
        project.addZoom(startMs: 150, endMs: 750, depth: 3, x: 0.4, y: 0.6)
        project.addText("Hello", startMs: 150, endMs: 750)
        project.addOverlay(type: "figure", startMs: 200, endMs: 600, x: 0.6, y: 0.6)
        project.addOverlay(type: "blur", startMs: 200, endMs: 600, x: 0.3, y: 0.3)
        project.crop(clipID: project.clips[0].id, x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        #expect(project.clips[0].crop?["width"] == 0.8)
        project.aspectRatio = "16:9"
        project.padding = 12
        let pipeline: VideoRenderPipeline
        do { pipeline = try await VideoRenderPipeline.make(project: project) } catch {
            Issue.record("Composing source failed: \(error)"); return
        }
        #expect(pipeline.videoComposition.mutableCopy() is AVMutableVideoComposition)
        #expect(pipeline.canvas == CGSize(width: 64, height: 36))
        #expect(abs(pipeline.duration - 1) < 0.01)

        let mp4 = directory.appendingPathComponent("output.mp4")
        do { try await pipeline.exportMP4(to: mp4) } catch {
            Issue.record("MP4 export failed: \(error)"); return
        }
        let exported = AVURLAsset(url: mp4)
        let duration = try await exported.load(.duration).seconds
        #expect(abs(duration - 1) < 0.1)
        let outputTrack = try #require(await exported.loadTracks(withMediaType: .video).first)
        let outputSize = try await outputTrack.load(.naturalSize)
        #expect(outputSize == pipeline.canvas)
        #expect(try FileManager.default.attributesOfItem(atPath: mp4.path)[.size] as? Int ?? 0 > 0)

        let compact = try await VideoRenderPipeline.make(project: project, maxDimension: 32)
        #expect(compact.canvas == CGSize(width: 32, height: 18))
        let compactMP4 = directory.appendingPathComponent("compact.mp4")
        try await compact.exportMP4(to: compactMP4)
        let compactTrack = try #require(
            await AVURLAsset(url: compactMP4).loadTracks(withMediaType: .video).first)
        #expect(try await compactTrack.load(.naturalSize) == compact.canvas)
        let notUpscaled = try await VideoRenderPipeline.make(project: project, maxDimension: 3840)
        #expect(notUpscaled.canvas == pipeline.canvas)

        let gif = directory.appendingPathComponent("output.gif")
        do { try await pipeline.exportGIF(to: gif, fps: 5) } catch {
            Issue.record("GIF export failed: \(error)"); return
        }
        let frames = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        #expect(CGImageSourceGetCount(frames) >= 4)
        let smaller = directory.appendingPathComponent("small.gif")
        try await pipeline.exportGIF(to: smaller, fps: 5, maxWidth: 32, loop: false)
        let resized = try #require(CGImageSourceCreateWithURL(smaller as CFURL, nil))
        let firstFrame = try #require(CGImageSourceCreateImageAtIndex(resized, 0, nil))
        #expect(firstFrame.width <= 32)
        let gifProperties = CGImageSourceCopyProperties(resized, nil) as? [String: Any]
        let gifDictionary =
            gifProperties?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
        #expect((gifDictionary?[kCGImagePropertyGIFLoopCount as String] as? Int) == 1)

        project.split(clipID: project.clips[0].id, at: 0.5)
        var clips = project.clips
        clips[1].rate = 2
        project.setClips(clips)
        #expect(project.clips[1].rate == 2)
        let sped = try await VideoRenderPipeline.make(project: project)
        #expect(abs(sped.duration - 0.75) < 0.01)
        let spedMP4 = directory.appendingPathComponent("sped.mp4")
        try await sped.exportMP4(to: spedMP4)
        let spedDuration = try await AVURLAsset(url: spedMP4).load(.duration).seconds
        #expect(abs(spedDuration - 0.75) < 0.1)

        var partial = VideoProject.create()
        partial.addAsset(source, duration: 1, width: 64, height: 64)
        var legacy = partial.root["legacyEditor"] as? [String: Any] ?? [:]
        legacy["speedRegions"] = [
            [
                "id": "speed_example", "clipId": partial.clips[0].id,
                "sourceStartSec": 0.2, "sourceEndSec": 0.6,
                "startMs": 200, "endMs": 600, "speed": 2,
            ]
        ]
        partial.root["legacyEditor"] = legacy
        let partialPipeline = try await VideoRenderPipeline.make(project: partial)
        #expect(partialPipeline.segments.count == 3)
        #expect(partialPipeline.segments.map(\.rate) == [1, 2, 1])
        #expect(abs(partialPipeline.duration - 0.8) < 0.01)
        try await partialPipeline.exportMP4(to: directory.appendingPathComponent("partial.mp4"))
    }

    private func frame(at seconds: Double, in url: URL) throws -> CGImage {
        try AVAssetImageGenerator(asset: AVURLAsset(url: url)).copyCGImage(
            at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
    }

    private func createVideo(
        at url: URL, brightness: UInt8 = 0,
        frameTimes: [Double] = (0..<30).map { Double($0) / 30 }, length: Double? = nil
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64, AVVideoHeightKey: 64,
            ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64,
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for (frame, time) in frameTimes.enumerated() {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
            let pixel = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(
                CVPixelBufferGetBaseAddress(pixel), Int32(min(255, frame * 4 + Int(brightness))),
                CVPixelBufferGetDataSize(pixel))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            #expect(
                adaptor.append(
                    pixel, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600)))
        }
        input.markAsFinished()
        if let length {
            writer.endSession(atSourceTime: CMTime(seconds: length, preferredTimescale: 600))
        }
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        #expect(writer.status == .completed)
    }

    private func createAudio(at url: URL) throws {
        let format = try #require(
            AVAudioFormat(
                standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
        buffer.frameLength = 44_100
        let channel = try #require(buffer.floatChannelData?[0])
        for index in 0..<44_100 {
            channel[index] = Float(sin(2 * Double.pi * 440 * Double(index) / 44_100)) * 0.1
        }
        try file.write(from: buffer)
    }
}
