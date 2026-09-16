import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import EdithKit

@Suite struct KnitRendererTests {
    static let cases: [(app: String, color: UInt32, chart: String)] = [
        ("Claude", 0xff_d58561, "atelier-claude"),
        ("Finder", 0xff_258de0, "atelier-finder"),
        ("Spotify", 0xff_497641, "atelier-spotify"),
        ("Messages", 0xff_55af51, "atelier-messages"),
        ("Notes", 0xff_f6f0d9, "atelier-notes"),
        ("WhatsApp", 0xff_6ea77b, "atelier-whatsapp"),
        ("Chrome", 0xff_f4f0e6, "atelier-chrome"),
        ("Plain", 0xff_d1495b, ""),
        ("Zigzag", 0xff_f2d2dc, "zigzag"),
        ("Checker", 0xff_f2eee4, "checker"),
        ("Braid", 0xff_f6f0de, "braid"),
        ("Trim", 0xff_ffffff, "trim"),
    ]

    @Test func collectionMatchesTheOriginalCounts() {
        #expect(SweaterChartCatalog.builtIn.count == 47)
        #expect(SweaterCollection.builtIn.count == 44)
    }

    @Test func everyCuratedAppResolvesToAKnownChart() {
        for rule in SweaterCollection.builtIn where !rule.chart.isEmpty {
            #expect(
                SweaterChartCatalog.chart(named: rule.chart) != nil,
                "\(rule.match) names a missing chart \(rule.chart)")
        }
    }

    @Test func longestPrefixWinsOverShorterOne() {
        #expect(SweaterCollection.rule(for: "Microsoft Teams")?.chart == "atelier-teams")
        #expect(SweaterCollection.rule(for: "Microsoft Word")?.chart == "atelier-word")
        #expect(SweaterCollection.rule(for: "claude helper (renderer)")?.match == "Claude")
        #expect(SweaterCollection.rule(for: "Unknown App") == nil)
    }

    @Test func userRulesOutrankTheBuiltInCollection() {
        let mine = [SweaterAppRule(match: "Finder", color: 0xff_00ff00, chart: "checker")]
        #expect(SweaterCollection.rule(for: "Finder", userRules: mine)?.color == 0xff_00ff00)
    }

    @Test func electronExecutablesResolveToTheirApp() {
        #expect(
            SweaterCollection.appName(
                fromExecutablePath: "/Applications/Cursor.app/Contents/MacOS/Electron") == "Cursor")
        #expect(SweaterCollection.appName(fromExecutablePath: "/usr/bin/true") == nil)
    }

    @Test func cuffChartsMoveTheirOuterRowOutOfTheChart() {
        let notes = SweaterChartCatalog.chart(named: "atelier-notes")
        #expect(notes?.cuffColor == 0xff_efc852)
        #expect(notes?.cells.contains(0xff_efc852) == false)
    }

    @Test func appColoursAreStableAcrossCallsAndCaseFolding() {
        let basket = SweaterBaskets.basket(named: "wool")
        let first = KnitMath.color(forApp: "Ghostty", basket: basket)
        #expect(KnitMath.color(forApp: "ghostty", basket: basket) == first)
        #expect(basket.colors.contains(first))
    }

    @Test func gaugeRisesToTheMinimumAPatternNeeds() {
        var settings = SweaterSettings(pattern: .chart("braid"), gauge: 3)
        #expect(settings.effectiveGauge == 12)
        settings.pattern = .plain
        #expect(settings.effectiveGauge == 3)
    }

    @Test func renderedBandsAreOpaqueAndSizeStable() throws {
        let context = try #require(Self.makeContext(width: 240, height: 160))
        let window = CGRect(x: 40, y: 40, width: 160, height: 80)
        KnitRenderer().draw(
            in: context, windowRect: window, radius: 10, band: 14,
            color: 0xff_d58561, chart: SweaterChartCatalog.chart(named: "atelier-claude"),
            dim: 0, tuck: 1, stitch: .stockinette, anchor: .corner, gauge: .standard)
        let image = try #require(context.makeImage())
        #expect(image.width == 240)
        #expect(image.height == 160)
        let band = try #require(Self.pixel(in: context, x: 34, y: 80))
        #expect(band.alpha == 255)
        let corner = try #require(Self.pixel(in: context, x: 5, y: 5))
        #expect(band != corner)
    }

    @Test func aChartlessWindowStillDrawsABand() throws {
        let context = try #require(Self.makeContext(width: 240, height: 160))
        KnitRenderer().draw(
            in: context, windowRect: CGRect(x: 40, y: 40, width: 160, height: 80), radius: 10,
            band: 14, color: 0xff_d1495b, chart: nil, dim: 0, tuck: 1, stitch: .stockinette,
            anchor: .corner, gauge: .standard)
        let band = try #require(Self.pixel(in: context, x: 34, y: 80))
        #expect(band.alpha == 255)
        #expect(band.red > band.blue)
    }

    @Test func degenerateGeometryDrawsNothingRatherThanCrashing() throws {
        let context = try #require(Self.makeContext(width: 64, height: 64))
        let renderer = KnitRenderer()
        for rect in [
            CGRect(x: 0, y: 0, width: 0, height: 0),
            CGRect(x: 0, y: 0, width: -10, height: 10),
            CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10),
        ] {
            renderer.draw(
                in: context, windowRect: rect, radius: 10, band: 14, color: 0xff_d1495b,
                chart: nil, dim: 0, tuck: 1, stitch: .stockinette, anchor: .corner,
                gauge: .standard)
        }
        #expect(Self.pixel(in: context, x: 32, y: 32)?.alpha == 0)
    }

    @Test func everyBuiltInChartRendersATile() throws {
        let renderer = KnitRenderer()
        for chart in SweaterChartCatalog.builtIn {
            let context = try #require(Self.makeContext(width: 180, height: 140))
            renderer.draw(
                in: context, windowRect: CGRect(x: 30, y: 30, width: 120, height: 80),
                radius: 10, band: 14, color: 0xff_d58561, chart: chart, dim: 0, tuck: 1,
                stitch: .stockinette, anchor: .corner, gauge: .standard)
            let band = Self.pixel(in: context, x: 24, y: 70)
            #expect(band?.alpha == 255, "\(chart.name) left its band unpainted")
        }
    }

    @Test func comparisonSheetRendersWhenAsked() throws {
        guard let destination = ProcessInfo.processInfo.environment["KNIT_SHEET"] else { return }
        let columns = 4, rows = 3, cellWidth = 260, cellHeight = 180, padding = 24
        let width = columns * cellWidth + padding
        let height = rows * cellHeight + padding
        let context = try #require(Self.makeContext(width: width, height: height))
        context.setFillColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let renderer = KnitRenderer()
        for (index, entry) in Self.cases.enumerated() {
            let column = index % columns
            let row = index / columns
            let window = CGRect(
                x: padding + column * cellWidth + 40, y: padding + row * cellHeight + 40,
                width: cellWidth - 100, height: cellHeight - 100)
            context.setFillColor(red: 0.20, green: 0.20, blue: 0.22, alpha: 1)
            context.fill(window)
            renderer.draw(
                in: context, windowRect: window, radius: 10, band: 14, color: entry.color,
                chart: entry.chart.isEmpty
                    ? nil : SweaterChartCatalog.chart(named: entry.chart),
                dim: 0, tuck: 1, stitch: .stockinette, anchor: .corner, gauge: .standard)
        }

        let image = try #require(context.makeImage())
        let url = URL(fileURLWithPath: destination)
        let sink = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(sink, image, nil)
        #expect(CGImageDestinationFinalize(sink))
    }

    static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGImageByteOrderInfo.order32Host.rawValue)
    }

    static func pixel(in context: CGContext, x: Int, y: Int)
        -> (alpha: UInt8, red: UInt8, green: UInt8, blue: UInt8)?
    {
        guard let raw = context.data else { return nil }
        let row = context.height - 1 - y
        let pixels = raw.assumingMemoryBound(to: UInt32.self)
        let value = pixels[row * (context.bytesPerRow / 4) + x]
        return (
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
        )
    }
}
