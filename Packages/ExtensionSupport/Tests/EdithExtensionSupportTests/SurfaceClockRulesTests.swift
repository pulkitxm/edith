import Foundation
import Testing
@testable import EdithExtensionSupport

@Suite struct SurfaceClockRulesTests {
    @Test func normalizesAndBoundsSavedCities() {
        #expect(
            SurfaceClockRules.zones("Asia/Kolkata,invalid,Asia/Kolkata,Europe/London") == [
                "Asia/Kolkata", "Europe/London",
            ])
        #expect(
            SurfaceClockRules.zones(TimeZone.knownTimeZoneIdentifiers.joined(separator: ","))
                .isEmpty)
        let valid = TimeZone.knownTimeZoneIdentifiers.prefix(20).joined(separator: ",")
        #expect(SurfaceClockRules.zones(valid).count == SurfaceClockRules.maxZones)
    }

    @Test func addingRejectsDuplicatesInvalidCitiesAndOverflow() {
        let current = "Asia/Kolkata"
        #expect(SurfaceClockRules.add("Asia/Kolkata", to: current) == current)
        #expect(SurfaceClockRules.add("invalid", to: current) == current)
        #expect(SurfaceClockRules.add("Europe/London", to: current) == "Asia/Kolkata,Europe/London")
        let full = TimeZone.knownTimeZoneIdentifiers.prefix(12).joined(separator: ",")
        #expect(SurfaceClockRules.add("Asia/Kolkata", to: full) == full)
    }

    @Test func searchAndOffsetsPreserveExistingClockSettings() {
        #expect(SurfaceClockRules.cityName("America/Argentina/Buenos_Aires") == "Buenos Aires")
        #expect(SurfaceClockRules.offsetLabel(seconds: 0) == "same time")
        #expect(SurfaceClockRules.offsetLabel(seconds: 19800) == "+5.5h")
        #expect(SurfaceClockRules.offsetLabel(seconds: -34200) == "-9.5h")
        #expect(
            SurfaceClockRules.zoneMatches(query: "new york", taken: []).contains("America/New_York")
        )
        #expect(SurfaceClockRules.zoneMatches(query: "TOKYO", taken: ["Asia/Tokyo"]).isEmpty)
        #expect(SurfaceClockRules.zoneMatches(query: "a", taken: []).count <= 14)
        #expect(
            SurfaceClockRules.zoneMatches(query: String(repeating: "x", count: 257), taken: [])
                .isEmpty)
        for zone in SurfaceClockRules.zoneSuggestions {
            #expect(TimeZone(identifier: zone) != nil)
        }
    }
}
