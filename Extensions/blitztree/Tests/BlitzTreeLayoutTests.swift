import AppKit
import EdithExtensionUI
import Foundation
import Testing

@testable import BlitzTreeExtension

@Suite struct BlitzTreeLayoutTests {
    @Test func preservesAreaAndWeightsWithoutOverlaps() {
        let weights = [60.0, 25, 10, 4, 1]
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 300)
        let rectangles = BlitzTreeLayout.rectangles(weights: weights, in: bounds)
        for index in weights.indices {
            let rect = rectangles[index]
            #expect(bounds.contains(rect))
            #expect(abs(rect.width * rect.height - 2400 * weights[index]) < 0.001)
            for other in rectangles.indices where other > index {
                let intersection = rect.intersection(rectangles[other])
                #expect(intersection.isNull || intersection.width * intersection.height < 0.001)
            }
        }
    }

    @Test func emptyAndZeroSizedEntriesDoNotCorruptLayout() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 800)
        #expect(BlitzTreeLayout.rectangles(weights: [], in: bounds).isEmpty)
        let rectangles = BlitzTreeLayout.rectangles(weights: [0, -1, .nan, 5], in: bounds)
        #expect(rectangles == [.zero, .zero, .zero, bounds])
        #expect(BlitzTreeLayout.rectangles(weights: [5], in: .zero) == [.zero])
    }
}

@Suite struct BlitzTreePaletteTests {
    @Test(arguments: AppTheme.allCases, [false, true])
    func everyToneFollowsTheThemeAndKeepsWhiteLabelsReadable(theme: AppTheme, dark: Bool) throws {
        let tones = BlitzTreePalette.tones(theme: theme, dark: dark)
        #expect(tones.count == 6)
        #expect(Set(tones.map(\.hexString)).count == 6)
        let accent = try #require(NSColor(theme.accent(dark: dark)).usingColorSpace(.sRGB))
        for tone in tones {
            #expect(BlitzTreePalette.contrast(.white, tone) >= 4.5)
            let distance = abs(tone.hueComponent - accent.hueComponent)
            #expect(min(distance, 1 - distance) <= 0.03)
        }
    }

    @Test func everyThemeGetsItsOwnPalette() {
        let palettes = AppTheme.allCases.map {
            BlitzTreePalette.tones(theme: $0, dark: false).map(\.hexString)
        }
        #expect(Set(palettes).count == AppTheme.allCases.count)
    }
}

extension NSColor {
    fileprivate var hexString: String {
        let srgb = usingColorSpace(.sRGB) ?? self
        return String(
            format: "%02X%02X%02X", Int((srgb.redComponent * 255).rounded()),
            Int((srgb.greenComponent * 255).rounded()), Int((srgb.blueComponent * 255).rounded()))
    }
}
