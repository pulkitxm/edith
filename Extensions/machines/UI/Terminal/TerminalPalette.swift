import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

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
        edithPalettes[EdithKey(theme: theme, dark: dark)]
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

    private static func color(_ value: UInt32) -> NSColor {
        NSColor(
            calibratedRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1)
    }
}
