import Testing

@testable import EdithKit

@Suite struct ColorFormattingTests {
    @Test func convertsPureRedToHSL() {
        let (h, s, l) = ColorFormatting.rgbToHSL(red: 1, green: 0, blue: 0)
        #expect(h == 0)
        #expect(s == 1)
        #expect(l == 0.5)
    }

    @Test func convertsPureGreenToHSL() {
        let (h, s, l) = ColorFormatting.rgbToHSL(red: 0, green: 1, blue: 0)
        #expect(abs(h - 1.0 / 3) < 0.0001)
        #expect(s == 1)
        #expect(l == 0.5)
    }

    @Test func grayHasNoSaturation() {
        let (h, s, l) = ColorFormatting.rgbToHSL(red: 0.5, green: 0.5, blue: 0.5)
        #expect(h == 0)
        #expect(s == 0)
        #expect(l == 0.5)
    }

    @Test func formatsHexUppercase() {
        #expect(ColorFormatting.hex(red: 1, green: 0, blue: 0) == "#FF0000")
        #expect(ColorFormatting.hex(red: 0, green: 0, blue: 0) == "#000000")
    }

    @Test func formatsRGB() {
        #expect(ColorFormatting.rgb(red: 1, green: 0.5019607843, blue: 0) == "rgb(255, 128, 0)")
    }

    @Test func formatsHSL() {
        #expect(ColorFormatting.hsl(red: 0, green: 1, blue: 0) == "hsl(120, 100%, 50%)")
    }

    @Test func formatsSwiftUIAndNSColorSource() {
        #expect(
            ColorFormatting.swiftUIColor(red: 1, green: 0, blue: 0)
                == "Color(red: 1.0000, green: 0.0000, blue: 0.0000)")
        #expect(
            ColorFormatting.nsColor(red: 1, green: 0, blue: 0)
                == "NSColor(red: 1.0000, green: 0.0000, blue: 0.0000, alpha: 1.0)")
    }

    @Test func stringForDispatchesToTheRightFormatter() {
        #expect(
            ColorFormatting.string(red: 1, green: 0, blue: 0, format: .hex)
                == ColorFormatting.hex(red: 1, green: 0, blue: 0))
        #expect(
            ColorFormatting.string(red: 1, green: 0, blue: 0, format: .hsl)
                == ColorFormatting.hsl(red: 1, green: 0, blue: 0))
    }
}
