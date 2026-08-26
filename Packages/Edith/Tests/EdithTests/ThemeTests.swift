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

    @Test func appSurfacesStayConstantAcrossThemes() {
        let key = AppStorageKeys.General.theme
        let original = SharedDefaults.store.object(forKey: key)
        defer {
            if let original {
                SharedDefaults.store.set(original, forKey: key)
            } else {
                SharedDefaults.store.removeObject(forKey: key)
            }
        }

        SharedDefaults.store.set(AppTheme.blue.rawValue, forKey: key)
        let bluePaper = DashSkin.paper(true)
        let blueCard = DashSkin.paper2(true)
        let blueAccent = DashSkin.accent(true)
        SharedDefaults.store.set(AppTheme.orange.rawValue, forKey: key)

        #expect(DashSkin.paper(true) == bluePaper)
        #expect(DashSkin.paper2(true) == blueCard)
        #expect(DashSkin.accent(true) != blueAccent)
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
}
