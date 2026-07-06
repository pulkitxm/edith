import Foundation

public enum PixelRulerUnit: String, CaseIterable, Codable, Sendable {
    case pixels
    case points

    public var displayName: String {
        switch self {
        case .pixels: "Pixels"
        case .points: "Points"
        }
    }
}

public enum PixelRulerCopyFormat: String, CaseIterable, Codable, Sendable {
    case times
    case x

    public var example: String {
        switch self {
        case .times: "120 × 48"
        case .x: "120x48"
        }
    }

    public func string(width: Int, height: Int) -> String {
        switch self {
        case .times: "\(width) × \(height)"
        case .x: "\(width)x\(height)"
        }
    }
}

public enum PixelGeometry {
    public static func devicePixels(forPoints points: Double, scale: Double) -> Int {
        Int((points * scale).rounded())
    }

    public static func measurement(devicePixels: Int, scale: Double, unit: PixelRulerUnit) -> Int {
        switch unit {
        case .pixels: devicePixels
        case .points: Int((Double(devicePixels) / scale).rounded())
        }
    }
}

public enum PixelEdgeWalker {
    public static func luminance(r: UInt8, g: UInt8, b: UInt8) -> Double {
        0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
    }

    public static func walk(
        from index: Int, step: Int, tolerance: Double, sample: (Int) -> Double?
    ) -> Int? {
        guard step != 0, let base = sample(index) else { return nil }
        var current = index
        while true {
            current += step
            guard let value = sample(current) else { return nil }
            if abs(value - base) >= tolerance { return current }
        }
    }
}
