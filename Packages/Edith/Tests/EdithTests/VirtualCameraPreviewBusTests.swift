import CoreVideo
import EdithCameraSupport
import Foundation
import Testing

@testable import EdithKit

@Suite(.serialized) struct VirtualCameraPreviewBusTests {
    private static func busFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "camera-preview-\(UUID().uuidString).bin")
    }

    private static func filledBuffer(width: Int, height: Int, pixel: UInt32) -> CVPixelBuffer? {
        guard let buffer = VirtualCameraPlaceholder.makeBuffer(width: width, height: height)
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                base.advanced(by: y * row + x * 4).storeBytes(of: pixel, as: UInt32.self)
            }
        }
        return buffer
    }

    @Test func framesCrossOnlyWhileTheWindowIsWatching() throws {
        let file = Self.busFile()
        let writer = VirtualCameraPreviewBus(file: file)
        let reader = VirtualCameraPreviewBus(file: file, unlinkOnClose: true)
        defer {
            writer.close()
            reader.close()
        }
        let source = try #require(Self.filledBuffer(width: 30, height: 18, pixel: 0xFF30_2010))
        #expect(reader.latest() == nil)
        writer.publish(source)
        #expect(reader.latest() == nil)
        writer.setWanted(true)
        #expect(reader.isWanted)
        writer.publish(source)
        let frame = try #require(reader.latest())
        #expect(CVPixelBufferGetWidth(frame) == VirtualCameraPreviewBus.previewWidth)
        #expect(CVPixelBufferGetHeight(frame) == VirtualCameraPreviewBus.previewHeight)
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        let pixel = CVPixelBufferGetBaseAddress(frame)?.load(as: UInt32.self)
        CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        #expect(pixel == 0xFF30_2010)
        #expect(reader.latest() == nil)
        writer.setWanted(false)
        writer.publish(source)
        #expect(reader.latest() == nil)
    }
}
