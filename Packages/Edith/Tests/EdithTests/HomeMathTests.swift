import Foundation
import Testing
@testable import Edith

@Suite struct HomeMathTests {
    @Test func salutationCoversTheWholeDay() {
        #expect(HomeMath.salutation(hour: 0) == "Up late")
        #expect(HomeMath.salutation(hour: 4) == "Up late")
        #expect(HomeMath.salutation(hour: 5) == "Good morning")
        #expect(HomeMath.salutation(hour: 11) == "Good morning")
        #expect(HomeMath.salutation(hour: 12) == "Good afternoon")
        #expect(HomeMath.salutation(hour: 16) == "Good afternoon")
        #expect(HomeMath.salutation(hour: 17) == "Good evening")
        #expect(HomeMath.salutation(hour: 21) == "Good evening")
        #expect(HomeMath.salutation(hour: 22) == "Up late")
    }

    @Test func clockLabelUsesTwelveHourFormat() {
        #expect(HomeMath.clockLabel(hour24: 0, minute: 0, second: 0) == "12:00:00")
        #expect(HomeMath.clockLabel(hour24: 12, minute: 5, second: 9) == "12:05:09")
        #expect(HomeMath.clockLabel(hour24: 13, minute: 30, second: 0) == "1:30:00")
        #expect(HomeMath.clockLabel(hour24: 23, minute: 59, second: 59) == "11:59:59")
    }

    @Test func cityNameUsesLastPathComponent() {
        #expect(HomeMath.cityName("America/New_York") == "New York")
        #expect(HomeMath.cityName("Asia/Kolkata") == "Kolkata")
        #expect(HomeMath.cityName("America/Argentina/Buenos_Aires") == "Buenos Aires")
        #expect(HomeMath.cityName("UTC") == "UTC")
    }

    @Test func offsetLabelFormatsWholeAndHalfHours() {
        #expect(HomeMath.offsetLabel(seconds: 0) == "same time")
        #expect(HomeMath.offsetLabel(seconds: 3600) == "+1h")
        #expect(HomeMath.offsetLabel(seconds: -3600) == "-1h")
        #expect(HomeMath.offsetLabel(seconds: 19800) == "+5.5h")
        #expect(HomeMath.offsetLabel(seconds: -34200) == "-9.5h")
        #expect(HomeMath.offsetLabel(seconds: 46800) == "+13h")
    }

    @Test func emptyQueryReturnsSuggestionsMinusTaken() {
        let taken: Set<String> = ["Europe/London", "Asia/Tokyo"]
        let matches = HomeMath.zoneMatches(query: "", taken: taken)
        #expect(!matches.contains("Europe/London"))
        #expect(!matches.contains("Asia/Tokyo"))
        #expect(matches.contains("Asia/Kolkata"))
        #expect(matches == HomeMath.zoneSuggestions.filter { !taken.contains($0) })
    }

    @Test func queryMatchesKnownZonesCaseInsensitively() {
        #expect(HomeMath.zoneMatches(query: "kolkata", taken: []).contains("Asia/Kolkata"))
        #expect(HomeMath.zoneMatches(query: "TOKYO", taken: []).contains("Asia/Tokyo"))
    }

    @Test func querySpacesMatchUnderscoredIdentifiers() {
        #expect(HomeMath.zoneMatches(query: "new york", taken: []).contains("America/New_York"))
    }

    @Test func queryExcludesTakenZones() {
        let matches = HomeMath.zoneMatches(query: "kolkata", taken: ["Asia/Kolkata"])
        #expect(!matches.contains("Asia/Kolkata"))
    }

    @Test func queryResultsAreCappedAtFourteen() {
        #expect(HomeMath.zoneMatches(query: "a", taken: []).count <= 14)
    }

    @Test func nonsenseQueryReturnsNothing() {
        #expect(HomeMath.zoneMatches(query: "zzzznotacity", taken: []).isEmpty)
    }

    @Test func topModelsAggregatesAcrossDays() {
        let monday = HeatDay(
            date: Date(),
            models: [
                NamedValue(id: "opus", name: "opus", value: 10),
                NamedValue(id: "haiku", name: "haiku", value: 1),
            ])
        let tuesday = HeatDay(
            date: Date(), models: [NamedValue(id: "opus", name: "opus", value: 5)])
        let top = HomeMath.topModels(days: [monday, tuesday, nil])
        #expect(top.map(\.name) == ["opus", "haiku"])
        #expect(top.first?.value == 15)
    }

    @Test func topModelsCapsAtLimit() {
        let day = HeatDay(
            date: Date(),
            models: (0..<5).map {
                NamedValue(id: "m\($0)", name: "m\($0)", value: Double($0))
            })
        #expect(HomeMath.topModels(days: [day]).count == 3)
        #expect(HomeMath.topModels(days: [day], limit: 2).count == 2)
    }

    @Test func topModelsEmptyForNoData() {
        #expect(HomeMath.topModels(days: [nil, nil]).isEmpty)
        #expect(HomeMath.topModels(days: []).isEmpty)
    }

    @Test func suggestionsAreAllValidTimeZones() {
        for id in HomeMath.zoneSuggestions {
            #expect(TimeZone(identifier: id) != nil, "\(id) is not a valid timezone")
        }
    }
}
