import CoreImage
import CoreVideo
import Foundation
@testable import VirtualCameraExtension

enum VirtualCameraFixtures {
    static let context = CIContext()

    static func quadrants(width: Int = 640, height: Int = 360) -> CVPixelBuffer? {
        guard let buffer = VirtualCameraPlaceholder.makeBuffer(width: width, height: height)
        else { return nil }
        let image = VirtualCameraRendererTests.quadrants(
            width: CGFloat(width), height: CGFloat(height))
        context.render(
            image, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return buffer
    }

    static func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> (red: Int, green: Int, blue: Int)
    {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return (0, 0, 0) }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.advanced(by: y * row + x * 4).assumingMemoryBound(to: UInt8.self)
        return (Int(bytes[2]), Int(bytes[1]), Int(bytes[0]))
    }
}
