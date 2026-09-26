import Foundation
import Testing

@testable import EdithKit

@Suite struct ClipboardColorValueTests {
    private static let hexCases: [(String, String)] = [
        ("#ff26a1", "#ff26a1"),
        ("#FF26A1", "#ff26a1"),
        ("  #000000\n", "#000000"),
        ("#fff", "#ffffff"),
        ("#f80", "#ff8800"),
        ("#f808", "#ff880088"),
        ("#11223380", "#11223380"),
    ]

    private static let functionCases: [(String, String)] = [
        ("rgb(255, 0, 0)", "#ff0000"),
        ("RGBA(0, 128, 255, 0.5)", "#0080ff80"),
        ("rgb(255 0 0 / 25%)", "#ff000040"),
        ("rgb(100%, 50%, 0%)", "#ff8000"),
        ("hsl(0, 100%, 50%)", "#ff0000"),
        ("hsl(120deg 100% 25%)", "#008000"),
        ("hsla(240, 100%, 50%, 0.4)", "#0000ff66"),
        ("hsl(-120, 100%, 50%)", "#0000ff"),
        ("hsl(60, 100%, 50%)", "#ffff00"),
        ("hsl(180, 100%, 50%)", "#00ffff"),
        ("hsl(300, 100%, 50%)", "#ff00ff"),
        ("hsl(0, 0%, 100%)", "#ffffff"),
    ]

    @Test(arguments: hexCases)
    func parsesHexNotations(text: String, expected: String) {
        #expect(ClipboardColorValue(parsing: text)?.hexString == expected)
    }

    @Test(arguments: functionCases)
    func parsesCSSFunctions(text: String, expected: String) {
        #expect(ClipboardColorValue(parsing: text)?.hexString == expected)
    }

    @Test func shortHexExpandsEachNibble() {
        let color = ClipboardColorValue(parsing: "#f80")
        #expect(color?.red == 1)
        #expect(color?.green == Double(0x88) / 255)
        #expect(color?.blue == 0)
        #expect(color?.alpha == 1)
    }

    @Test(arguments: [
        "", "#", "#ff", "#12345", "#1234567", "#ggg", "ff26a1", "#ff26a1 extra",
        "rgb(256, 0, 0)", "rgb(1, 2)", "rgb(1, 2, 3, 4, 5)", "rgb(a, b, c)",
        "rgba(0, 0, 0, 2)", "hsl(0, 200%, 50%)", "cmyk(0, 0, 0, 0)", "rgb 1 2 3",
        "rgb(1, 2, 3", "hsl(nan, 10%, 10%)", String(repeating: "#fff", count: 20),
    ])
    func rejectsValuesThatAreNotColors(text: String) {
        #expect(ClipboardColorValue(parsing: text) == nil)
    }

    @Test func clampsComponentsIntoUnitRange() {
        let color = ClipboardColorValue(red: 2, green: -1, blue: .nan, alpha: 5)
        #expect(color == ClipboardColorValue(red: 1, green: 0, blue: 0, alpha: 1))
    }

    @Test func formatsBackToHexWithAlphaOnlyWhenTranslucent() {
        #expect(ClipboardColorValue(parsing: "#FF26A1")?.hexString == "#ff26a1")
        #expect(ClipboardColorValue(parsing: "rgba(255, 0, 0, 0.5)")?.hexString == "#ff000080")
        #expect(ClipboardColorValue(parsing: "#abc")?.hexString == "#aabbcc")
    }
}
