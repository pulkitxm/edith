import EdithExtensionUI
import EdithExtensionSupport
import AVFoundation
import CoreImage
import ImageIO
import Testing
@testable import StudioExtension

@Suite struct VideoReviewOverlayTests {
    @Test func rationalMarkersMappedWaveformAndRepeatedCellsUseOutputGeometry() throws {
        let fps = try VideoMarkerFrameRate(numerator: 30000, denominator: 1001)
        let markers = try [
            VideoMarker(id: "beat", frame: 15, frameRate: fps, kind: .transient),
            VideoMarker(id: "outside", frame: 60, frameRate: fps),
        ]
        var options = VideoEditorService.ReviewOverlays()
        options.showBeatMarkers = true
        options.waveformAssetID = "clicks"
        let mapping = VideoEditorService.AudioMarkerMapping(
            sourceInSeconds: 1.25, sourceOutSeconds: 3, outputStartSeconds: 0.5, playbackRate: 2)
        options.waveformMapping = mapping
        let result = VideoBeatAnalysis.Result(
            sampleRate: 1000, sampleCount: 4000,
            waveform: (0..<4).map {
                .init(startSample: Int64($0 * 1000), sampleCount: 1000, peak: 0.5, meanSquare: 0.1)
            }, transients: [], transientsTruncated: false, tempoEstimate: nil)
        let analysis = VideoEditorService.AudioAnalysisReport(
            version: 1, assetID: "clicks", sourcePath: "/synthetic.caf",
            samplePositionUnit: "source_samples", sampleRateUnit: "Hz", durationSeconds: 4,
            analysis: result, mapping: mapping, frameRate: fps, markerDocument: nil)
        let report = try VideoEditorService.reviewOverlayGeometry(
            options: options, analysis: analysis, markers: markers,
            frames: [.init(frame: 15, time: 0.5005), .init(frame: 15, time: 0.5005)],
            duration: 1, sheetWidth: 1024)
        #expect(report.markers.count == 1)
        #expect(report.markers[0].frame == 15 && report.markers[0].frameRate == fps)
        #expect(abs(report.markers[0].x - 512.5) < 0.000001)
        #expect(report.cells.map(\.cell) == [1, 2])
        #expect(report.cells.allSatisfy { abs($0.x - 512.5) < 0.000001 })
        #expect(report.waveform.map(\.sourceStartSeconds) == [1.25, 2])
        #expect(report.waveform.map(\.sourceEndSeconds) == [2, 2.25])
        #expect(report.waveform.map(\.outputStartSeconds) == [0.5, 0.875])
        #expect(report.waveform.map(\.outputEndSeconds) == [0.875, 1])
        #expect(report.waveform.map(\.xStart) == [512, 887])
        #expect(report.waveform.map(\.xEnd) == [887, 1012])
        #expect(report.waveformAmplitudeUnit == "source_linear_peak_before_mix")
    }

    @Test func nativeOverlayPreservesAllOriginalPixelsAndUsesSharedSourceAnalysis() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("review.openscreen")
        let movie = try await VideoEditorServiceTests.movie(in: directory)
        let audio = directory.appendingPathComponent("clicks.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000))
        buffer.frameLength = 24000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<24000 { samples[index] = index % 4000 == 2000 ? 0.8 : 0 }
        try AVAudioFile(forWriting: audio, settings: format.settings).write(from: buffer)
        var project = VideoProject.create(title: "Synthetic rhythm review")
        project.addAsset(movie, duration: 1, width: 64, height: 64)
        project.addAudio(audio, duration: 3, at: 0)
        let audioID = try #require(
            project.assets.first { $0.raw["kind"] as? String == "audio" }?.id)
        project.videoSettings = VideoSettings(frameRateNumerator: 30000, frameRateDenominator: 1001)
        let fps = try VideoMarkerFrameRate(numerator: 30000, denominator: 1001)
        _ = try project.addMarker(
            atFrame: 15, frameRate: fps, label: "Synthetic beat", kind: .transient)
        try project.save(to: url)
        let before = try Data(contentsOf: url)
        let plain = directory.appendingPathComponent("plain.png")
        let overlaid = directory.appendingPathComponent("overlaid.png")
        let times = [0.0, 0.501, 0.501]
        let original = try await VideoEditorService.contactSheet(
            url, times: times, columns: 2, cellWidth: 160, to: plain)
        var options = VideoEditorService.ReviewOverlays()
        options.showBeatMarkers = true
        options.waveformAssetID = try #require(project.audioTracks.first?.id)
        options.waveformMapping = .init(
            sourceInSeconds: 1, sourceOutSeconds: 3, outputStartSeconds: 0.25, playbackRate: 2)
        let report = try await VideoEditorService.contactSheet(
            url, times: times, columns: 2, cellWidth: 160, to: overlaid, overlays: options)
        let overlay = try #require(report.overlays)
        #expect(original.overlays == nil)
        #expect(report.width == original.width && report.height == original.height + 132)
        #expect(report.frames.map(\.frame) == [0, 15, 15])
        #expect(overlay.cells[1].x == overlay.cells[2].x)
        #expect(abs(overlay.cells[1].x - overlay.markers[0].x) < 0.000001)
        #expect(overlay.waveform.first?.sourceStartSeconds == 1)
        #expect(overlay.waveform.first?.outputStartSeconds == 0.25)
        #expect(overlay.waveform.last?.outputEndSeconds == overlay.outputDurationSeconds)
        #expect(overlay.waveform.count <= 2048)
        let shared = try await VideoEditorService.analyzeAudio(url, assetID: audioID)
        #expect(overlay.waveformSampleRateHz == shared.analysis.sampleRate)
        #expect(overlay.waveform.contains { $0.sourcePeak > 0.7 })
        func image(_ path: URL) throws -> CGImage {
            let source = try #require(CGImageSourceCreateWithURL(path as CFURL, nil))
            return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        func pixels(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            CIContext().render(
                CIImage(cgImage: image), toBitmap: &bytes, rowBytes: image.width * 4,
                bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return bytes
        }
        let actual = try image(overlaid)
        let crop = try #require(
            actual.cropping(to: CGRect(x: 0, y: 0, width: original.width, height: original.height)))
        #expect(pixels(crop) == pixels(try image(plain)))
        var markerPixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(
            CIImage(cgImage: actual), toBitmap: &markerPixel, rowBytes: 4,
            bounds: CGRect(x: Int(overlay.markers[0].x), y: 88, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        #expect(markerPixel[0] > 150 && markerPixel[2] < 100)
        #expect(try Data(contentsOf: url) == before)
        let outputBefore = try Data(contentsOf: overlaid)
        let videoID = try #require(
            project.assets.first { $0.raw["kind"] as? String == "video" }?.id)
        for (asset, start, code) in [
            (videoID, 0.0, "invalid_audio"), (audioID, 2.0, "invalid_value"),
        ] {
            options.waveformAssetID = asset
            options.waveformMapping = .init(
                sourceInSeconds: 1, sourceOutSeconds: 3, outputStartSeconds: start, playbackRate: 2)
            do {
                _ = try await VideoEditorService.contactSheet(
                    url, times: [0], to: overlaid, overwrite: true, overlays: options)
                Issue.record("Invalid waveform unexpectedly succeeded")
            } catch let failure as VideoEditorService.Failure {
                #expect(failure.code == code)
            }
            #expect(try Data(contentsOf: overlaid) == outputBefore)
            #expect(try Data(contentsOf: url) == before)
        }
    }

    @Test func invalidSelectionsPreserveProjectAndDestinationAndStillMarkersWork() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await VideoEditorServiceTests.movie(in: directory)
        let image = directory.appendingPathComponent("synthetic.png")
        let url = directory.appendingPathComponent("still.openscreen")
        var project = VideoProject.create(title: "Synthetic still")
        try project.addStillAsset(image, duration: 1, metadata: VideoStillMedia.metadata(at: image))
        _ = try project.addMarker(atFrame: 15)
        try project.save(to: url)
        let before = try Data(contentsOf: url)
        let destination = directory.appendingPathComponent("sheet.png")
        let sentinel = Data("existing synthetic destination".utf8)
        try sentinel.write(to: destination)
        for (asset, mapped, code) in [
            ("missing", true, "invalid_asset"),
            (try #require(project.assets.first?.id), true, "invalid_asset"),
            ("missing", false, "invalid_mapping"),
        ] {
            var options = VideoEditorService.ReviewOverlays()
            options.waveformAssetID = asset
            if mapped {
                options.waveformMapping = .init(
                    sourceInSeconds: 0, sourceOutSeconds: 1, outputStartSeconds: 0, playbackRate: 1)
            }
            do {
                _ = try await VideoEditorService.contactSheet(
                    url, times: [0], to: destination, overwrite: true, overlays: options)
                Issue.record("Invalid selection unexpectedly succeeded")
            } catch let failure as VideoEditorService.Failure {
                #expect(failure.code == code)
            }
            #expect(try Data(contentsOf: url) == before)
            #expect(try Data(contentsOf: destination) == sentinel)
        }
        var options = VideoEditorService.ReviewOverlays()
        options.showBeatMarkers = true
        let result = try await VideoEditorService.contactSheet(
            url, times: [0], to: destination, overwrite: true, overlays: options)
        #expect(result.overlays?.markers.count == 1)
        #expect(result.overlays?.waveform.isEmpty == true)
    }

    @Test func waveformUsesCapturedProjectWhenTheSavedAudioReferenceChanges() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try await VideoEditorServiceTests.movie(in: directory)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
        buffer.frameLength = 8000
        let samples = try #require(buffer.floatChannelData?[0])
        let original = directory.appendingPathComponent("original.caf")
        let replacement = directory.appendingPathComponent("replacement.caf")
        for (path, peak) in [(original, Float(0.8)), (replacement, Float(0.2))] {
            for index in 0..<8000 { samples[index] = peak }
            try AVAudioFile(forWriting: path, settings: format.settings).write(from: buffer)
        }
        let url = directory.appendingPathComponent("snapshot.openscreen")
        var project = VideoProject.create(title: "Synthetic snapshot")
        project.addAsset(movie, duration: 1, width: 64, height: 64)
        project.addAudio(original, duration: 1, at: 0)
        try project.save(to: url)
        let captured = try VideoEditorService.open(url)
        let track = try #require(captured.audioTracks.first)
        let pipeline = try await VideoRenderPipeline.make(project: captured)
        let destination = directory.appendingPathComponent("existing.png")
        let existing = Data("existing synthetic destination".utf8)
        try existing.write(to: destination)
        for field in ["originalPath", "edithAudioPath"] {
            var revised = try VideoProject.open(url)
            var assets = revised.assets.map(\.raw)
            let index = try #require(assets.firstIndex { $0["id"] as? String == track.assetID })
            assets[index]["originalPath"] = original.path
            assets[index][field] = replacement.path
            revised.root["assets"] = assets
            try revised.save(to: url)
            let saved = try Data(contentsOf: url)
            var options = VideoEditorService.ReviewOverlays()
            options.waveformAssetID = track.id
            options.waveformMapping = .init(
                sourceInSeconds: 0, sourceOutSeconds: 1, outputStartSeconds: 0, playbackRate: 1)
            let report = try #require(
                try await VideoEditorService.reviewOverlayAnalysis(
                    project: captured, options: options, pipeline: pipeline))
            #expect(report.sourcePath == original.path)
            #expect(report.analysis.waveform.map(\.peak).max() == 0.8)
            let reopened = try await VideoEditorService.analyzeAudio(url, assetID: track.id)
            #expect(reopened.sourcePath == replacement.path)
            #expect(reopened.analysis.waveform.map(\.peak).max() == 0.2)
            #expect(try Data(contentsOf: destination) == existing)
            #expect(try Data(contentsOf: url) == saved)
        }
    }
}
