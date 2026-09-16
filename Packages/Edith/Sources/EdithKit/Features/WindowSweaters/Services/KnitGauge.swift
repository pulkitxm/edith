import CoreGraphics
import Foundation

public struct KnitGauge: Equatable, Sendable {
    public var rows: Double
    public var aspect: Double
    public var rowOverlap: Double
    public var yarn: Double
    public var bow: Double
    public var jitter: Double
    public var ground: Double
    public var ambient: Double
    public var relief: Double
    public var sheen: Double
    public var tuck: Double

    public static let standard = KnitGauge(
        rows: 6, aspect: 1.35, rowOverlap: 0.12, yarn: 0.48, bow: 0.28, jitter: 0.035,
        ground: 0.98, ambient: 0.94, relief: 0.70, sheen: 0.10, tuck: 14)

    public init(
        rows: Double, aspect: Double, rowOverlap: Double, yarn: Double, bow: Double,
        jitter: Double, ground: Double, ambient: Double, relief: Double, sheen: Double,
        tuck: Double
    ) {
        self.rows = rows
        self.aspect = aspect
        self.rowOverlap = rowOverlap
        self.yarn = yarn
        self.bow = bow
        self.jitter = jitter
        self.ground = ground
        self.ambient = ambient
        self.relief = relief
        self.sheen = sheen
        self.tuck = tuck
    }

    var sculpted: KnitGauge {
        var material = self
        material.rowOverlap = 0.05
        material.yarn = 0.40
        material.ground = 0.94
        material.ambient = 0.84
        material.relief = 1.65
        material.sheen = 0.28
        return material
    }
}

public enum KnitMath {
    public static func mix(_ value: UInt32) -> UInt32 {
        var hash = value
        hash ^= hash >> 16
        hash = hash &* 0x85eb_ca6b
        hash ^= hash >> 13
        hash = hash &* 0xc2b2_ae35
        hash ^= hash >> 16
        return hash
    }

    public static func color(forWindow wid: UInt32, basket: SweaterBasket) -> UInt32 {
        guard !basket.colors.isEmpty else { return 0xff_e1e3e4 }
        return basket.colors[Int(mix(wid) % UInt32(basket.colors.count))]
    }

    public static func color(forApp app: String, basket: SweaterBasket) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in app.lowercased().utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return color(forWindow: hash, basket: basket)
    }

    static func noise(_ a: Int, _ b: Int) -> Float {
        let value = sin(Float(a) * 12.9898 + Float(b) * 78.233) * 43758.5453
        return value - value.rounded(.down)
    }

    static func components(_ argb: UInt32) -> (a: Double, r: Double, g: Double, b: Double) {
        (
            Double((argb >> 24) & 0xff) / 255,
            Double((argb >> 16) & 0xff) / 255,
            Double((argb >> 8) & 0xff) / 255,
            Double(argb & 0xff) / 255
        )
    }
}
