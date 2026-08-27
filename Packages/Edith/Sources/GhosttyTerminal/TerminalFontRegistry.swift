import AppKit
import CoreText
import Foundation

public enum TerminalFontRegistry {
    public static let family = "Symbols Nerd Font Mono"

    private static let registrationResult: Bool = {
        guard
            let url = Bundle.module.url(
                forResource: "SymbolsNerdFontMono-Regular", withExtension: "ttf",
                subdirectory: "Fonts")
        else { return false }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    public static func register() {
        _ = registrationResult
    }

    public static func monospacedFont(ofSize size: CGFloat) -> NSFont {
        register()
        let primary = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let symbols = NSFontDescriptor(fontAttributes: [.family: family])
        let descriptor = primary.fontDescriptor.addingAttributes([.cascadeList: [symbols]])
        return NSFont(descriptor: descriptor, size: size) ?? primary
    }
}
