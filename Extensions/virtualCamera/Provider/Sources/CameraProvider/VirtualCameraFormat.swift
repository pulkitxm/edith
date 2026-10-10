import Foundation

public struct VirtualCameraFormat: Hashable, Sendable, Codable {
    public let width: Int
    public let height: Int
    public let frameRate: Int

    public init(width: Int, height: Int, frameRate: Int) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }

    public static let hd1080 = VirtualCameraFormat(width: 1920, height: 1080, frameRate: 30)
    public static let hd720 = VirtualCameraFormat(width: 1280, height: 720, frameRate: 30)
    public static let supported: [VirtualCameraFormat] = [.hd1080, .hd720]
    public static let standard = hd1080

    public var label: String { "\(width)x\(height) at \(frameRate) fps" }
    public var aspectRatio: Double { Double(width) / Double(height) }
    public var frameDurationNanoseconds: UInt64 { 1_000_000_000 / UInt64(max(frameRate, 1)) }

    public static func format(at index: Int) -> VirtualCameraFormat {
        supported.indices.contains(index) ? supported[index] : standard
    }

    public static func index(of format: VirtualCameraFormat) -> Int? {
        supported.firstIndex(of: format)
    }
}
