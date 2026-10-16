import AppKit
import Observation
import SwiftUI

public let brandAccent = Color(.sRGB, red: 217 / 255, green: 119 / 255, blue: 87 / 255)

public let usageSage = Color(.sRGB, red: 106 / 255, green: 141 / 255, blue: 115 / 255)

public enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case accent, blue, indigo, teal, green, purple, pink, red, orange

    public var id: String { rawValue }

    public init(storedName: String) {
        self = AppTheme(rawValue: storedName) ?? .accent
    }

    public var color: Color {
        switch self {
        case .accent: brandAccent
        case .blue: .blue
        case .indigo: .indigo
        case .teal: .teal
        case .green: .green
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        }
    }

    public func accent(dark: Bool) -> Color {
        Color(accentNSColor(dark: dark))
    }

    public var accent: Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                accentNSColor(dark: appearance.isDark)
            })
    }

    func accentNSColor(dark: Bool) -> NSColor {
        if self == .accent {
            return dark ? ThemeColor.nsColor("#e08a6a") : ThemeColor.nsColor("#d97757")
        }
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var base = NSColor.black
        appearance?.performAsCurrentDrawingAppearance {
            base = NSColor(color).usingColorSpace(.sRGB) ?? .black
        }
        guard dark else { return base }
        return base.blended(withFraction: 0.12, of: .white) ?? base
    }
}

extension NSAppearance {
    public var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

enum ThemeColor {
    static func nsColor(_ hex: String) -> NSColor {
        var digits = hex
        if digits.hasPrefix("#") { digits.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: digits).scanHexInt64(&value)
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1)
    }

    static func color(_ hex: String) -> Color {
        Color(nsColor(hex))
    }
}

@MainActor
@Observable
public final class ThemeStore {
    public static let shared = ThemeStore(defaults: SharedDefaults.store)

    public private(set) var theme: AppTheme
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observer: ThemeDefaultsObserver?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        theme = Self.stored(in: defaults)
        observer = ThemeDefaultsObserver(defaults: defaults) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        let next = Self.stored(in: defaults)
        if next != theme { theme = next }
    }

    nonisolated static func stored(in defaults: UserDefaults) -> AppTheme {
        AppTheme(storedName: defaults.string(forKey: AppStorageKeys.General.theme) ?? "")
    }

    public nonisolated static var current: AppTheme {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { shared.theme }
        }
        return stored(in: SharedDefaults.store)
    }
}

private final class ThemeDefaultsObserver: NSObject, @unchecked Sendable {
    private let defaults: UserDefaults
    private let onChange: @Sendable () -> Void

    init(defaults: UserDefaults, onChange: @escaping @Sendable () -> Void) {
        self.defaults = defaults
        self.onChange = onChange
        super.init()
        defaults.addObserver(self, forKeyPath: AppStorageKeys.General.theme, context: nil)
    }

    deinit {
        defaults.removeObserver(self, forKeyPath: AppStorageKeys.General.theme)
    }

    override func observeValue(
        forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        onChange()
    }
}

extension Color {
    public static var themeAccent: Color { ThemeStore.current.accent }
}

public let themePalette: [(name: String, color: Color)] = AppTheme.allCases.dropFirst().map {
    ($0.rawValue, $0.color)
}

public func themeColor(_ name: String) -> Color {
    AppTheme(storedName: name).accent
}

extension View {
    public func themedControls() -> some View {
        tint(Color.themeAccent)
    }
}
