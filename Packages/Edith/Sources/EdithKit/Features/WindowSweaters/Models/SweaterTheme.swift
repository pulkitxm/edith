import Foundation

public enum SweaterTheme {
    public static let processName = "Edith"

    static let themeYarns: [AppTheme: UInt32] = [
        .accent: 0xff_d97757,
        .blue: 0xff_0091ff,
        .indigo: 0xff_6d7cff,
        .teal: 0xff_00d2e0,
        .green: 0xff_30d158,
        .purple: 0xff_db34f2,
        .pink: 0xff_ff375f,
        .red: 0xff_ff4245,
        .orange: 0xff_ff9230,
    ]

    static let motif = [
        "..a.....a...",
        ".a.a...a.a..",
        "a...a.a...a.",
        ".a.a...a.a..",
        "..a.....a...",
        "bbbbbbbbbbbb",
    ]

    public static func dressesWindows(of app: String) -> Bool {
        app.caseInsensitiveCompare(processName) == .orderedSame
            || app.lowercased().hasPrefix(processName.lowercased() + " ")
    }

    public static func yarn(for theme: AppTheme) -> UInt32 {
        fulled(themeYarns[theme] ?? themeYarns[.accent]!)
    }

    public static func chart(for theme: AppTheme) -> SweaterChart {
        let base = yarn(for: theme)
        let spec = SweaterChartSpec(
            name: "atelier-edith-\(theme.rawValue)", rows: motif,
            yarn: [tinted(base, towards: 0.82), tinted(base, towards: 0.30)])
        return SweaterChartCatalog.chart(from: spec)
    }

    static func fulled(_ color: UInt32) -> UInt32 {
        var (hue, saturation, brightness) = hsb(color)
        saturation = min(saturation, 0.72)
        brightness = min(max(brightness, 0.42), 0.86)
        return argb(hue: hue, saturation: saturation, brightness: brightness)
    }

    static func tinted(_ color: UInt32, towards amount: Double) -> UInt32 {
        let wool = (r: 245.0, g: 240.0, b: 230.0)
        let red = Double((color >> 16) & 0xff)
        let green = Double((color >> 8) & 0xff)
        let blue = Double(color & 0xff)
        let mix = { (from: Double, to: Double) -> UInt32 in
            UInt32(min(255, max(0, from + (to - from) * amount)).rounded())
        }
        return 0xff00_0000 | (mix(red, wool.r) << 16) | (mix(green, wool.g) << 8)
            | mix(blue, wool.b)
    }

    static func hsb(_ color: UInt32) -> (hue: Double, saturation: Double, brightness: Double) {
        let red = Double((color >> 16) & 0xff) / 255
        let green = Double((color >> 8) & 0xff) / 255
        let blue = Double(color & 0xff) / 255
        let high = max(red, max(green, blue))
        let low = min(red, min(green, blue))
        let delta = high - low
        var hue = 0.0
        if delta > 0 {
            if high == red {
                hue = (green - blue) / delta
            } else if high == green {
                hue = 2 + (blue - red) / delta
            } else {
                hue = 4 + (red - green) / delta
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, high == 0 ? 0 : delta / high, high)
    }

    static func argb(hue: Double, saturation: Double, brightness: Double) -> UInt32 {
        let sector = (hue - hue.rounded(.down)) * 6
        let index = Int(sector)
        let fraction = sector - Double(index)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))
        let channels: (Double, Double, Double)
        switch index % 6 {
        case 0: channels = (brightness, t, p)
        case 1: channels = (q, brightness, p)
        case 2: channels = (p, brightness, t)
        case 3: channels = (p, q, brightness)
        case 4: channels = (t, p, brightness)
        default: channels = (brightness, p, q)
        }
        let byte = { (value: Double) -> UInt32 in
            UInt32(min(255, max(0, value * 255)).rounded())
        }
        return 0xff00_0000 | (byte(channels.0) << 16) | (byte(channels.1) << 8)
            | byte(channels.2)
    }
}
