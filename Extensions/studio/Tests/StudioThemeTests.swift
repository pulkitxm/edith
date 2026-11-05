import AppKit
import EdithExtensionCore
import EdithExtensionSupport
import EdithExtensionUI
import EdithStudio
import SwiftUI
import Testing

@testable import StudioExtension

@MainActor
@Suite(.serialized)
struct StudioThemeTests {
    private static let peachHue = 15.0...30.0

    private func withTheme(_ theme: AppTheme, _ body: () throws -> Void) async throws {
        let defaults = ExtensionScope.process.defaults()
        let prior = defaults.object(forKey: AppStorageKeys.General.theme)
        defaults.set(theme.rawValue, forKey: AppStorageKeys.General.theme)
        defer {
            if let prior {
                defaults.set(prior, forKey: AppStorageKeys.General.theme)
            } else {
                defaults.removeObject(forKey: AppStorageKeys.General.theme)
            }
        }
        #expect(await StudioTestFiles.waitUntil { ThemeStore.current == theme })
        try body()
    }

    private func saturatedHues(of view: some View) throws -> [Double] {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        var hues: [Double] = []
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                    color.alphaComponent > 0.5, color.saturationComponent > 0.3
                else { continue }
                hues.append(color.hueComponent * 360)
            }
        }
        return hues
    }

    @Test func waveColorDefaultFollowsTheThemeAndKeepsTheBrandDefault() throws {
        let tool = try #require(StudioCatalog.tool("audio.to-video"))
        #expect(tool.themedDefaultSettings(theme: .accent) == tool.defaultSettings)
        let themed = try #require(tool.themedDefaultSettings(theme: .teal)["color"]?.text)
        #expect(themed.uppercased() != StudioTool.brandColorDefault)
        let color = try #require(StudioColor(hex: themed))
        let expected = try #require(
            NSColor(AppTheme.teal.accent(dark: true)).usingColorSpace(.sRGB))
        #expect(abs(color.green - expected.greenComponent) < 0.01)
        let watermark = try #require(StudioCatalog.tool("pdf.watermark"))
        #expect(watermark.themedDefaultSettings(theme: .teal) == watermark.defaultSettings)
    }

    @Test func toolIconsFollowTheThemeInEveryGroup() async throws {
        let tools = ["pdf.merge", "audio.trim", "audio.to-video", "image.compress"].compactMap {
            StudioCatalog.tool($0)
        }
        #expect(tools.count == 4)
        for theme in [AppTheme.teal, .green] {
            try await withTheme(theme) {
                let accent = try #require(
                    NSColor(theme.accent(dark: false)).usingColorSpace(.sRGB))
                for tool in tools {
                    let hues = try saturatedHues(
                        of: StudioToolIcon(tool: tool).environment(\.colorScheme, .light))
                    #expect(!hues.isEmpty, "\(tool.id) drew no tinted pixels")
                    #expect(!hues.contains { Self.peachHue.contains($0) }, "\(tool.id) kept peach")
                    #expect(
                        hues.allSatisfy { abs($0 - accent.hueComponent * 360) < 24 },
                        "\(tool.id) left the \(theme.rawValue) accent")
                }
            }
        }
    }

    @Test func extensionSourcesNeverReachForSystemAccentOrLinkColors() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
        for folder in ["Studio", "VideoEditor", "UIBridge"] {
            let files = FileManager.default.enumerator(
                at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            for case let file as URL in files ?? FileManager.DirectoryEnumerator()
            where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                #expect(!source.contains("accentColor"), "\(file.lastPathComponent)")
                #expect(!source.contains("controlAccentColor"), "\(file.lastPathComponent)")
                #expect(!source.contains(".buttonStyle(.link)"), "\(file.lastPathComponent)")
            }
        }
    }
}
