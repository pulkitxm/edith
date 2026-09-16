import Foundation
import Testing

@testable import EdithKit

@Suite struct BifrostConversionTests {
    @Test(arguments: [
        ("12 km in miles", "7.456454307"),
        ("12km to mi", "7.456454307"),
        ("convert 3 meters to feet", "9.842519685"),
        ("100 f to c", "37.77777778"),
        ("0 c in f", "32"),
        ("300 k to c", "26.85"),
        ("2 hours in minutes", "120"),
        ("5 gb to mb", "5000"),
        ("1 gib in mib", "1024"),
        ("how many miles is 42 km", "26.09759007"),
        ("how many grams in 2 pounds", "907.18474"),
        ("90 kmh to mph", "55.9234073"),
        ("1 cup in ml", "236.5882365"),
        ("180 degrees to radians", "3.141592654"),
        ("2 * 3 km in m", "6000"),
        ("km to mi", "0.6213711922"),
    ]) func convertsSentences(input: String, expected: String) {
        let conversion = BifrostConversionParser.parse(input)
        #expect(conversion?.copyText == expected, "\(input)")
    }

    @Test(arguments: [
        "", "safari", "12 km", "12 km in kilograms", "12 bananas in apples",
        "notes to self", "mail to inbox", "5 to 10", "in to",
    ]) func refusesWhatIsNotAConversion(input: String) {
        #expect(BifrostConversionParser.parse(input) == nil, "\(input)")
    }

    @Test func readsTheUnitGluedToItsNumber() throws {
        let conversion = try #require(BifrostConversionParser.parse("5in to cm"))
        #expect(conversion.source.id == "inch")
        #expect(conversion.target.id == "centimeter")
        #expect(conversion.copyText == "12.7")
    }

    @Test func describesBothSidesInWords() throws {
        let conversion = try #require(BifrostConversionParser.parse("1 km in m"))
        #expect(conversion.detail == "1 kilometer = 1,000 meters")
        #expect(conversion.display == "1,000 m")
    }

    @Test func everyUnitAliasResolvesToExactlyOneUnit() {
        for unit in BifrostUnitCatalog.units {
            #expect(BifrostUnitCatalog.unit(id: unit.id)?.id == unit.id)
            for alias in [unit.symbol, unit.singular, unit.plural] {
                let resolved = BifrostUnitCatalog.unit(alias: alias)
                #expect(resolved != nil, "\(unit.id) alias \(alias) resolves to nothing")
                #expect(
                    resolved?.dimension == unit.dimension,
                    "\(unit.id) alias \(alias) crosses dimensions")
            }
        }
    }

    @Test func everyDimensionHasUnitsAndARoundTrip() {
        for dimension in BifrostDimension.allCases {
            let units = BifrostUnitCatalog.units(in: dimension)
            #expect(units.count >= 3, "\(dimension.rawValue) is too small to be useful")
            guard let first = units.first, let last = units.last else { continue }
            let forward = BifrostUnitCatalog.convert(7, from: first, to: last)
            let back = forward.flatMap { BifrostUnitCatalog.convert($0, from: last, to: first) }
            #expect(back.map { abs($0 - 7) < 1e-6 } == true, "\(dimension.rawValue)")
        }
    }

    @Test func refusesToCrossDimensions() {
        let kilometer = BifrostUnitCatalog.unit(id: "kilometer")!
        let gram = BifrostUnitCatalog.unit(id: "gram")!
        #expect(BifrostUnitCatalog.convert(1, from: kilometer, to: gram) == nil)
    }

    @Test func unitIdentifiersAreUnique() {
        let identifiers = BifrostUnitCatalog.units.map(\.id)
        #expect(Set(identifiers).count == identifiers.count)
    }
}
