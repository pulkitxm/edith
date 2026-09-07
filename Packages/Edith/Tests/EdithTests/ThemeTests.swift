import EdithKit
import SwiftUI
import Testing
@testable import Edith

@Suite(.serialized) struct ThemeTests {
    @Test func accentNameReturnsBrandAccent() {
        #expect(themeColor("accent") == brandAccent)
    }

    @Test func paletteNamesResolveToTheirColors() {
        for entry in themePalette {
            #expect(themeColor(entry.name) == entry.color)
        }
    }

    @Test func unknownNameFallsBackToBrandAccent() {
        #expect(themeColor("chartreuse") == brandAccent)
        #expect(themeColor("") == brandAccent)
    }

    @Test func paletteNamesAreUnique() {
        let names = themePalette.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test func everyStoredThemeResolvesToItsOwnAccent() {
        for theme in AppTheme.allCases {
            #expect(AppTheme(storedName: theme.rawValue) == theme)
            #expect(themeColor(theme.rawValue) == theme.color)
        }
    }

    @Test func invalidStoredThemeResolvesToTheBrandTheme() {
        #expect(AppTheme(storedName: "chartreuse") == .accent)
    }

    @Test func appSurfacesStayConstantWhileAccentsChange() {
        #expect(rgb(DashSkin.paper(true)) == [26, 23, 20])
        #expect(rgb(DashSkin.paper2(true)) == [34, 29, 25])
        #expect(DashSkin.accent(true, theme: .blue) != DashSkin.accent(true, theme: .orange))
    }

    @Test func databaseSurfacesFollowTheSelectedAppTheme() {
        let blue = DatabaseThemePalette(dark: true, theme: .blue)
        let orange = DatabaseThemePalette(dark: true, theme: .orange)

        #expect(rgb(blue.canvas) != rgb(orange.canvas))
        #expect(rgb(blue.panel) != rgb(orange.panel))
        #expect(rgb(blue.grid) != rgb(orange.grid))
        #expect(rgb(blue.accent) != rgb(orange.accent))
    }

    @Test func appViewsDoNotBypassSharedThemeTokens() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = packageRoot.appendingPathComponent("Sources/Edith")
        let banned = [
            "brandAccent", "Color(nsColor: .windowBackgroundColor)",
            ".background(dark ? Color.black", ".background(Color.white",
        ]
        let files = FileManager.default.enumerator(
            at: sourceRoot, includingPropertiesForKeys: nil)
        var violations: [String] = []

        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            for token in banned where source.contains(token) {
                violations.append("\(url.lastPathComponent): \(token)")
            }
        }

        #expect(violations.isEmpty, "theme token bypasses: \(violations.sorted())")
    }

    private func rgb(_ color: Color) -> [Int] {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return [resolved.redComponent, resolved.greenComponent, resolved.blueComponent].map {
            Int(($0 * 255).rounded())
        }
    }
}
