import AppKit
import EdithKit
import SwiftUI

extension QuinjetTerminal {
    var label: String {
        switch self {
        case .embedded: "Embedded"
        case .cmux: "cmux"
        }
    }

    var icon: String {
        switch self {
        case .embedded: "rectangle.inset.filled"
        case .cmux: "macwindow.on.rectangle"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .embedded: true
        case .cmux: QuinjetCMUXLauncher.executable != nil
        }
    }
}

extension QuinjetTheme {
    var label: String {
        switch rawValue {
        case QuinjetTheme.quinjet.rawValue: "Quinjet"
        case QuinjetTheme.catppuccin.rawValue: "Catppuccin"
        case QuinjetTheme.dracula.rawValue: "Dracula"
        case QuinjetTheme.everforest.rawValue: "Everforest"
        case QuinjetTheme.gruvbox.rawValue: "Gruvbox"
        case QuinjetTheme.nord.rawValue: "Nord"
        case QuinjetTheme.one.rawValue: "One"
        case QuinjetTheme.rosePine.rawValue: "Rosé Pine"
        case QuinjetTheme.solarized.rawValue: "Solarized"
        case QuinjetTheme.tokyoNight.rawValue: "Tokyo Night"
        case QuinjetTheme.ayu.rawValue: "Ayu"
        case QuinjetTheme.monokai.rawValue: "Monokai"
        case QuinjetTheme.github.rawValue: "GitHub"
        default:
            rawValue.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
        }
    }
}

struct TerminalPalette: Equatable {
    private struct EdithKey: Hashable {
        let theme: AppTheme
        let dark: Bool
    }

    var background: NSColor
    var foreground: NSColor
    var caret: NSColor
    var selectionBackground: NSColor
    var selectionForeground: NSColor
    var ansi: [NSColor]

    static func == (lhs: TerminalPalette, rhs: TerminalPalette) -> Bool {
        lhs.background.isEqual(rhs.background)
            && lhs.foreground.isEqual(rhs.foreground)
            && lhs.caret.isEqual(rhs.caret)
            && lhs.selectionBackground.isEqual(rhs.selectionBackground)
            && lhs.selectionForeground.isEqual(rhs.selectionForeground)
            && lhs.ansi.elementsEqual(rhs.ansi, by: { $0.isEqual($1) })
    }

    static func edith(dark: Bool) -> TerminalPalette {
        let theme = AppTheme(
            storedName: SharedDefaults.store.string(forKey: AppStorageKeys.General.theme)
                ?? AppTheme.accent.rawValue)
        return edith(dark: dark, theme: theme)
    }

    static func edith(dark: Bool, theme: AppTheme) -> TerminalPalette {
        return edithPalettes[EdithKey(theme: theme, dark: dark)]
            ?? .make(
                background: NSColor(DashSkin.paper(dark, theme: theme)),
                foreground: NSColor(DashSkin.ink(dark, theme: theme)),
                caret: NSColor(DashSkin.accent(dark, theme: theme)), dark: dark)
    }

    private static let edithPalettes: [EdithKey: TerminalPalette] = {
        var palettes: [EdithKey: TerminalPalette] = [:]
        for theme in AppTheme.allCases {
            for dark in [false, true] {
                palettes[EdithKey(theme: theme, dark: dark)] = .make(
                    background: NSColor(DashSkin.paper(dark, theme: theme)),
                    foreground: NSColor(DashSkin.ink(dark, theme: theme)),
                    caret: NSColor(DashSkin.accent(dark, theme: theme)), dark: dark)
            }
        }
        return palettes
    }()

    static func quinjet(
        theme: QuinjetTheme, appearance: QuinjetAppearance
    ) -> TerminalPalette {
        let values = colors(theme: theme, appearance: appearance)
        return make(
            background: color(values.0), foreground: color(values.1), caret: color(values.2),
            dark: appearance == .dark)
    }

    static func quinjet(configuration: QuinjetLaunchConfiguration) -> TerminalPalette {
        guard let hostTheme = configuration.hostTheme else {
            return quinjet(theme: configuration.theme, appearance: configuration.appearance)
        }
        let values = hostTheme.palette(for: configuration.appearance)
        return make(
            background: color(values.background), foreground: color(values.textStrong),
            caret: color(values.accent), dark: configuration.appearance == .dark)
    }

    private static func make(
        background: NSColor, foreground: NSColor, caret: NSColor, dark: Bool
    ) -> TerminalPalette {
        let selectionBackground = blend(background, with: caret, by: dark ? 0.34 : 0.2)
        return TerminalPalette(
            background: background, foreground: foreground, caret: caret,
            selectionBackground: selectionBackground, selectionForeground: foreground,
            ansi: ansi(background: background, foreground: foreground, accent: caret, dark: dark))
    }

    private static func ansi(
        background: NSColor, foreground: NSColor, accent: NSColor, dark: Bool
    ) -> [NSColor] {
        let normal: [UInt32] =
            dark
            ? [0xe06c75, 0x98c379, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2]
            : [0xe45649, 0x50a14f, 0xc18401, 0x4078f2, 0xa626a4, 0x0184bc]
        let bright: [UInt32] =
            dark
            ? [0xff7b86, 0xb3e192, 0xffd68a, 0x7fc1ff, 0xdf8df0, 0x70d5df]
            : [0xca1243, 0x3f953a, 0x986801, 0x2f69d9, 0x8f2591, 0x007a9f]
        let mutedForeground = blend(foreground, with: background, by: dark ? 0.22 : 0.3)
        let faintForeground = blend(foreground, with: background, by: dark ? 0.52 : 0.58)
        let accentBright = blend(accent, with: dark ? .white : .black, by: dark ? 0.18 : 0.12)
        return [
            background, color(normal[0]), color(normal[1]), color(normal[2]), accent,
            color(normal[4]), color(normal[5]), mutedForeground, faintForeground,
            color(bright[0]), color(bright[1]), color(bright[2]), accentBright,
            color(bright[4]), color(bright[5]), foreground,
        ]
    }

    private static func blend(_ color: NSColor, with target: NSColor, by fraction: CGFloat)
        -> NSColor
    {
        let base = color.usingColorSpace(.sRGB) ?? color
        let resolvedTarget = target.usingColorSpace(.sRGB) ?? target
        return base.blended(withFraction: fraction, of: resolvedTarget) ?? base
    }

    private static func colors(
        theme: QuinjetTheme, appearance: QuinjetAppearance
    ) -> (UInt32, UInt32, UInt32) {
        switch (theme.rawValue, appearance) {
        case (QuinjetTheme.quinjet.rawValue, .dark): (0x0d1117, 0xe6edf3, 0x58a6ff)
        case (QuinjetTheme.quinjet.rawValue, .light): (0xffffff, 0x1f2328, 0x0969da)
        case (QuinjetTheme.catppuccin.rawValue, .dark): (0x1e1e2e, 0xf5e0dc, 0x89b4fa)
        case (QuinjetTheme.catppuccin.rawValue, .light): (0xeff1f5, 0x3c3f58, 0x1e66f5)
        case (QuinjetTheme.dracula.rawValue, .dark): (0x282a36, 0xffffff, 0x66d9ef)
        case (QuinjetTheme.dracula.rawValue, .light): (0xf8f8f2, 0x20212b, 0x005cc5)
        case (QuinjetTheme.everforest.rawValue, .dark): (0x2d353b, 0xe4d9bd, 0x7fbbb3)
        case (QuinjetTheme.everforest.rawValue, .light): (0xfdf6e3, 0x4b565c, 0x3a94c5)
        case (QuinjetTheme.gruvbox.rawValue, .dark): (0x282828, 0xfbf1c7, 0x83a598)
        case (QuinjetTheme.gruvbox.rawValue, .light): (0xfbf1c7, 0x282828, 0x458588)
        case (QuinjetTheme.nord.rawValue, .dark): (0x2e3440, 0xe5e9f0, 0x81a1c1)
        case (QuinjetTheme.nord.rawValue, .light): (0xeceff4, 0x2e3440, 0x426b94)
        case (QuinjetTheme.one.rawValue, .dark): (0x282c34, 0xd7dae0, 0x61afef)
        case (QuinjetTheme.one.rawValue, .light): (0xfafafa, 0x202227, 0x4078f2)
        case (QuinjetTheme.rosePine.rawValue, .dark): (0x191724, 0xeeeaf4, 0xc4a7e7)
        case (QuinjetTheme.rosePine.rawValue, .light): (0xfaf4ed, 0x403d52, 0x907aa9)
        case (QuinjetTheme.solarized.rawValue, .dark): (0x002b36, 0xfdf6e3, 0x268bd2)
        case (QuinjetTheme.solarized.rawValue, .light): (0xfdf6e3, 0x073642, 0x268bd2)
        case (QuinjetTheme.tokyoNight.rawValue, .dark): (0x1a1b26, 0xd5d6db, 0x7aa2f7)
        case (QuinjetTheme.tokyoNight.rawValue, .light): (0xe1e2e7, 0x2e3c64, 0x2e7de9)
        case (QuinjetTheme.ayu.rawValue, .dark): (0x0b0e14, 0xe6e1cf, 0x59c2ff)
        case (QuinjetTheme.ayu.rawValue, .light): (0xfafafa, 0x3f454a, 0x399ee6)
        case (QuinjetTheme.monokai.rawValue, .dark): (0x272822, 0xf5f4f1, 0x66d9ef)
        case (QuinjetTheme.monokai.rawValue, .light): (0xf9f8f5, 0x272822, 0x007fa3)
        case (QuinjetTheme.github.rawValue, .dark): (0x0d1117, 0xf0f6fc, 0x2f81f7)
        case (QuinjetTheme.github.rawValue, .light): (0xffffff, 0x24292f, 0x0969da)
        default:
            appearance == .dark
                ? (0x0d1117, 0xe6edf3, 0x58a6ff)
                : (0xffffff, 0x1f2328, 0x0969da)
        }
    }

    private static func color(_ value: UInt32) -> NSColor {
        NSColor(
            calibratedRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1)
    }
}

private struct QuinjetLaunchConfigurationKey: EnvironmentKey {
    static let defaultValue = QuinjetLaunchConfiguration.default
}

extension EnvironmentValues {
    var quinjetLaunchConfiguration: QuinjetLaunchConfiguration {
        get { self[QuinjetLaunchConfigurationKey.self] }
        set { self[QuinjetLaunchConfigurationKey.self] = newValue }
    }
}

enum QuinjetLaunchError: LocalizedError {
    case cmuxUnavailable
    case cmuxLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .cmuxUnavailable: "cmux is not installed in Applications."
        case .cmuxLaunchFailed(let message): "cmux could not open Quinjet: \(message)"
        }
    }
}

enum QuinjetCMUXLauncher {
    static var executable: URL? {
        QuinjetCMUX.executable()
    }

    static func launch(
        request: QuinjetLaunchRequest, replacing workspaceID: String?
    ) async throws -> String {
        guard executable != nil else { throw QuinjetLaunchError.cmuxUnavailable }
        return try await execute(QuinjetCMUX.launchScript(request: request, replacing: workspaceID))
    }

    static func focus(workspaceID: String) async throws {
        _ = try await execute(QuinjetCMUX.focusScript(workspaceID: workspaceID))
    }

    static func close(workspaceID: String) async throws {
        _ = try await execute(QuinjetCMUX.closeScript(workspaceID: workspaceID))
    }

    static func appleScriptQuote(_ value: String) -> String {
        QuinjetCMUX.appleScriptQuote(value)
    }

    private static func execute(_ source: String) async throws -> String {
        try await QuinjetBackgroundOperation.run {
            guard let script = NSAppleScript(source: source) else {
                throw QuinjetLaunchError.cmuxLaunchFailed("the launch request was invalid")
            }
            var details: NSDictionary?
            let result = script.executeAndReturnError(&details)
            if let details {
                let message = details[NSAppleScript.errorMessage] as? String ?? "unknown error"
                throw QuinjetLaunchError.cmuxLaunchFailed(message)
            }
            return result.stringValue ?? ""
        }
    }
}

enum QuinjetBackgroundOperation {
    static func run<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await Task.detached(priority: .userInitiated, operation: operation).value
    }
}
