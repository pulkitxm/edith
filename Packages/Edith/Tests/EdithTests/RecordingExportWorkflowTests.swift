import AVFoundation
import AppKit
import SwiftUI
import CoreGraphics
import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit
@testable import EdithHelper

@Suite(.serialized) struct RecordingExportWorkflowTests {
    @Test func syntheticTakeExportsThroughTheDaemon() async throws {
        let defaults = SharedDefaults.store
        let suiteKey = "suiteMediaEnabled"
        let abilityKey = AppStorageKeys.Tabs.captureToolsEnabled
        let suiteBefore = defaults.object(forKey: suiteKey)
        let abilityBefore = defaults.object(forKey: abilityKey)
        defaults.set(true, forKey: suiteKey)
        defaults.set(true, forKey: abilityKey)
        defer {
            defaults.set(suiteBefore, forKey: suiteKey)
            defaults.set(abilityBefore, forKey: abilityKey)
        }
        var take = try ScreenRecordingLibrary.makeTake(source: .area)
        let folder = ScreenRecordingLibrary.folderURL(for: take.id)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = ScreenRecordingLibrary.masterURL(for: take.id)
        let writer = try AVAssetWriter(outputURL: source, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 320, AVVideoHeightKey: 180,
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 180,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            for _ in 0..<500 where !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }
            var pixel: CVPixelBuffer?
            let pool = try #require(adaptor.pixelBufferPool)
            #expect(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess)
            let buffer = try #require(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = try #require(
                CGContext(
                    data: CVPixelBufferGetBaseAddress(buffer), width: 320, height: 180,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
            context.setFillColor(CGColor(red: 0.08, green: 0.12, blue: 0.23, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
            context.setFillColor(CGColor(red: 0.3, green: 0.75, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: CGFloat(30 + frame * 6), y: 60, width: 64, height: 60))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            #expect(
                adaptor.append(
                    buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 15)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        take.duration = 2
        take.pixelWidth = 320
        take.pixelHeight = 180
        take.completedAt = Date()
        try ScreenRecordingLibrary.update(take)
        let output = folder.appendingPathComponent("edited.mp4")
        var document = ScreenRecordingEditDocument(trimStart: 0.2, trimEnd: 1.8)
        document.preset.width = 640
        document.preset.frameRate = 15
        document.padding = 20
        document.texts = [ScreenRecordingTextOverlay(text: "Release preview", start: 0.2, end: 1.6)]
        let service = try AgentTaskService(directory: nil)
        await RecordingExportWorkflow.register(on: service)
        let request = AgentTaskSubmission(
            operation: ScreenRecordingOperation.export.descriptor.id.rawValue,
            title: "Export synthetic recording",
            payload: try AgentPayload.encode(
                RecordingExportRequest(
                    take: take, document: document, destination: output)))
        _ = try await service.submit(request)
        var status = try await service.status(request.id)
        for _ in 0..<600 where !status.snapshot.state.isTerminal {
            try await Task.sleep(for: .milliseconds(100))
            status = try await service.status(request.id)
        }
        #expect(status.snapshot.state == .succeeded)
        let result = try AgentPayload.decode(URL.self, from: #require(status.result))
        #expect(result == output)
        let asset = AVURLAsset(url: result)
        #expect(try await asset.load(.duration).seconds > 1)
        #expect(FileManager.default.fileExists(atPath: source.path))
        if let directory = ProcessInfo.processInfo.environment["EDITH_RENDER_DUMP"] {
            let destination = URL(fileURLWithPath: directory).appendingPathComponent(
                "screen-recorder.mp4")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: result, to: destination)
            try await renderEditor(
                take: take, document: document, output: result, directory: directory)
        }
        await service.shutdown()
    }

    @MainActor private func renderEditor(
        take: ScreenRecordingTake, document: ScreenRecordingEditDocument, output: URL,
        directory: String
    ) async throws {
        let model = ScreenRecordingEditorModel(take: take)
        model.document = document
        model.finishedURL = output
        let hosting = NSHostingView(
            rootView: ScreenRecordingEditorView(model: model)
                .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark))
        let window = TestWindowHost.window(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760))
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        defer { window.close() }
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 1100, height: 760)
        window.orderFront(nil)
        await model.player.seek(to: CMTime(seconds: 0.6, preferredTimescale: 600))
        try await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("recording-editor.png"))
    }
}
