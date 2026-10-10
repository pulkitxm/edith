import CoreGraphics
import CoreVideo
import Foundation
import Testing

@testable import VirtualCameraExtension

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

    @Test func unfilteredReferencesCrossIndependentlyAndOnlyWhenChanged() throws {
        let file = Self.busFile()
        let writer = VirtualCameraPreviewBus(file: file)
        let reader = VirtualCameraPreviewBus(file: file, unlinkOnClose: true)
        defer {
            writer.close()
            reader.close()
        }
        let frame = try #require(Self.filledBuffer(width: 30, height: 18, pixel: 0xFF30_2010))
        let context = try #require(
            CGContext(
                data: nil, width: 224, height: 126, bitsPerComponent: 8, bytesPerRow: 224 * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(
            try #require(
                CGColor(
                    colorSpace: CGColorSpaceCreateDeviceRGB(), components: [1, 0, 0, 1])))
        context.fill(CGRect(x: 0, y: 0, width: 224, height: 126))
        let reference = try #require(context.makeImage())
        writer.publish(frame, reference: reference)
        #expect(reader.latestReference() == nil)
        writer.setWanted(true)
        writer.publish(frame, reference: reference)
        let received = try #require(reader.latestReference())
        let data = try #require(received.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        #expect(Array(UnsafeBufferPointer(start: bytes, count: 4)) == [0, 0, 255, 255])
        #expect(reader.latest() != nil)
        #expect(reader.latestReference() == nil)
        writer.publish(frame, reference: reference)
        #expect(reader.latest() != nil)
        #expect(reader.latestReference() == nil)
        context.setFillColor(
            try #require(
                CGColor(
                    colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0, 1, 0, 1])))
        context.fill(CGRect(x: 0, y: 0, width: 224, height: 126))
        writer.publish(frame, reference: try #require(context.makeImage()))
        #expect(reader.latestReference() != nil)
    }
}
