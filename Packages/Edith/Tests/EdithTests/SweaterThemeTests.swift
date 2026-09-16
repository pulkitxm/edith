import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import EdithKit

@Suite struct SweaterThemeTests {
    @Test func edithWindowsAreRecognisedByProcessName() {
        #expect(SweaterTheme.dressesWindows(of: "Edith"))
        #expect(SweaterTheme.dressesWindows(of: "edith"))
        #expect(SweaterTheme.dressesWindows(of: "Edith Menu Bar"))
        #expect(!SweaterTheme.dressesWindows(of: "EdithClone"))
        #expect(!SweaterTheme.dressesWindows(of: "Finder"))
    }

    @Test func everyThemeHasItsOwnYarn() {
        let yarns = AppTheme.allCases.map(SweaterTheme.yarn(for:))
        #expect(Set(yarns).count == AppTheme.allCases.count)
        for yarn in yarns { #expect(yarn >> 24 == 0xff) }
    }

    @Test func theAccentThemeKeepsEdithsOwnColour() {
        #expect(SweaterTheme.yarn(for: .accent) == 0xff_d97757)
    }

    @Test func fullingTamesNeonSystemColoursIntoWool() {
        let raw = SweaterTheme.themeYarns[.red]!
        let wool = SweaterTheme.yarn(for: .red)
        let (rawHue, rawSaturation, _) = SweaterTheme.hsb(raw)
        let (woolHue, woolSaturation, woolBrightness) = SweaterTheme.hsb(wool)
        #expect(abs(rawHue - woolHue) < 0.02)
        #expect(woolSaturation < rawSaturation)
        let quantisation = 1.0 / 255
        #expect(woolSaturation <= 0.72 + quantisation)
        #expect(woolBrightness <= 0.86 + quantisation)
    }

    @Test func eachThemeChartIsNamedAndTwoToned() {
        for theme in AppTheme.allCases {
            let chart = SweaterTheme.chart(for: theme)
            #expect(chart.name == "atelier-edith-\(theme.rawValue)")
            #expect(chart.width == 12)
            #expect(chart.height == 6)
            let yarns = Set(chart.cells.filter { $0 != 0 })
            #expect(yarns.count == 2, "\(theme.rawValue) should knit two contrast yarns")
        }
    }

    @Test func chartYarnsAreLighterThanTheBase() {
        let base = SweaterTheme.yarn(for: .accent)
        let chart = SweaterTheme.chart(for: .accent)
        let brightness = { (c: UInt32) in SweaterTheme.hsb(c).brightness }
        for yarn in Set(chart.cells.filter { $0 != 0 }) {
            #expect(brightness(yarn) > brightness(base))
        }
    }

    @Test func themeSheetRendersWhenAsked() throws {
        guard let destination = ProcessInfo.processInfo.environment["THEME_SHEET"] else { return }
        let themes = AppTheme.allCases
        let columns = 3
        let rows = (themes.count + columns - 1) / columns
        let cellWidth = 260, cellHeight = 170, padding = 22
        let width = columns * cellWidth + padding
        let height = rows * cellHeight + padding
        let context = try #require(KnitRendererTests.makeContext(width: width, height: height))
        context.setFillColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let renderer = KnitRenderer()
        for (index, theme) in themes.enumerated() {
            let column = index % columns
            let row = rows - 1 - index / columns
            let window = CGRect(
                x: padding + column * cellWidth + 42, y: padding + row * cellHeight + 40,
                width: cellWidth - 104, height: cellHeight - 96)
            context.setFillColor(red: 0.17, green: 0.17, blue: 0.19, alpha: 1)
            context.fill(window)
            renderer.draw(
                in: context, windowRect: window, radius: 10, band: 16,
                color: SweaterTheme.yarn(for: theme), chart: SweaterTheme.chart(for: theme),
                dim: 0, tuck: 1, stitch: .stockinette, anchor: .corner, gauge: .standard)
        }
        let image = try #require(context.makeImage())
        let sink = try #require(
            CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: destination) as CFURL, UTType.png.identifier as CFString, 1,
                nil))
        CGImageDestinationAddImage(sink, image, nil)
        #expect(CGImageDestinationFinalize(sink))
    }
}
