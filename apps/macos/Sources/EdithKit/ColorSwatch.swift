import AppKit
import Foundation
import SwiftUI

public enum ColorProfile: String, CaseIterable, Codable, Sendable {
    case sRGB
    case displayP3

    public var displayName: String {
        switch self {
        case .sRGB: "sRGB"
        case .displayP3: "Display P3"
        }
    }

    public var nsColorSpace: NSColorSpace {
        switch self {
        case .sRGB: .sRGB
        case .displayP3: .displayP3
        }
    }
}

public enum ColorCopyFormat: String, CaseIterable, Sendable {
    case hex, rgb, hsl, swiftUI, nsColor

    public var displayName: String {
        switch self {
        case .hex: "Hex"
        case .rgb: "rgb()"
        case .hsl: "hsl()"
        case .swiftUI: "SwiftUI Color"
        case .nsColor: "NSColor"
        }
    }
}

public struct ColorSwatch: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let red: Double
    public let green: Double
    public let blue: Double
    public let profile: ColorProfile
    public let pickedAt: Date

    public init(
        id: UUID = UUID(), red: Double, green: Double, blue: Double, profile: ColorProfile,
        pickedAt: Date = Date()
    ) {
        self.id = id
        self.red = red
        self.green = green
        self.blue = blue
        self.profile = profile
        self.pickedAt = pickedAt
    }

    public var color: Color {
        switch profile {
        case .sRGB: Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
        case .displayP3: Color(.displayP3, red: red, green: green, blue: blue, opacity: 1)
        }
    }

    public func string(for format: ColorCopyFormat) -> String {
        ColorFormatting.string(red: red, green: green, blue: blue, format: format)
    }
}

public enum ColorFormatting {
    public static func string(red: Double, green: Double, blue: Double, format: ColorCopyFormat)
        -> String
    {
        switch format {
        case .hex: hex(red: red, green: green, blue: blue)
        case .rgb: rgb(red: red, green: green, blue: blue)
        case .hsl: hsl(red: red, green: green, blue: blue)
        case .swiftUI: swiftUIColor(red: red, green: green, blue: blue)
        case .nsColor: nsColor(red: red, green: green, blue: blue)
        }
    }

    public static func hex(red: Double, green: Double, blue: Double) -> String {
        String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    public static func rgb(red: Double, green: Double, blue: Double) -> String {
        "rgb(\(byte(red)), \(byte(green)), \(byte(blue)))"
    }

    public static func hsl(red: Double, green: Double, blue: Double) -> String {
        let (h, s, l) = rgbToHSL(red: red, green: green, blue: blue)
        return
            "hsl(\(Int((h * 360).rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)"
    }

    public static func swiftUIColor(red: Double, green: Double, blue: Double) -> String {
        "Color(red: \(decimal(red)), green: \(decimal(green)), blue: \(decimal(blue)))"
    }

    public static func nsColor(red: Double, green: Double, blue: Double) -> String {
        "NSColor(red: \(decimal(red)), green: \(decimal(green)), blue: \(decimal(blue)), alpha: 1.0)"
    }

    public static func rgbToHSL(red: Double, green: Double, blue: Double) -> (
        h: Double, s: Double, l: Double
    ) {
        let maxV = max(red, green, blue)
        let minV = min(red, green, blue)
        let l = (maxV + minV) / 2
        guard maxV != minV else { return (0, 0, l) }
        let d = maxV - minV
        let s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
        let h: Double
        if maxV == red {
            h = ((green - blue) / d + (green < blue ? 6 : 0)) / 6
        } else if maxV == green {
            h = ((blue - red) / d + 2) / 6
        } else {
            h = ((red - green) / d + 4) / 6
        }
        return (h, s, l)
    }

    private static func byte(_ value: Double) -> Int {
        Int((min(max(value, 0), 1) * 255).rounded())
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.4f", min(max(value, 0), 1))
    }
}

public enum ColorHistoryStore {
    private static let key = "colorPickerHistory"

    public static func load() -> [ColorSwatch] {
        guard let data = SharedDefaults.store.data(forKey: key),
            let swatches = try? JSONDecoder().decode([ColorSwatch].self, from: data)
        else { return [] }
        return swatches
    }

    public static func add(_ swatch: ColorSwatch, limit: Int) {
        save(inserting(swatch, into: load(), limit: limit))
    }

    public static func inserting(_ swatch: ColorSwatch, into history: [ColorSwatch], limit: Int)
        -> [ColorSwatch]
    {
        Array(([swatch] + history).prefix(max(0, limit)))
    }

    public static func clear() {
        SharedDefaults.store.removeObject(forKey: key)
    }

    private static func save(_ swatches: [ColorSwatch]) {
        guard let data = try? JSONEncoder().encode(swatches) else { return }
        SharedDefaults.store.set(data, forKey: key)
    }
}
