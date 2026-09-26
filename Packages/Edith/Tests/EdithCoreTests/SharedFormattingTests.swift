import Foundation
import Testing

@testable import EdithCore

@Suite struct TextColumnsTests {
    @Test func padLeavesTextThatAlreadyFillsTheWidth() {
        #expect(TextColumns.pad("name", to: 4) == "name")
        #expect(TextColumns.pad("longer", to: 3) == "longer")
        #expect(TextColumns.pad("", to: 0) == "")
    }

    @Test func padAppendsSpacesUpToTheWidth() {
        #expect(TextColumns.pad("id", to: 5) == "id   ")
        #expect(TextColumns.pad("", to: 2) == "  ")
    }

    @Test func leftPadInsertsSpacesBeforeTheText() {
        #expect(TextColumns.leftPad("7", to: 4) == "   7")
        #expect(TextColumns.leftPad("done", to: 4) == "done")
        #expect(TextColumns.leftPad("overflow", to: 2) == "overflow")
    }

    @Test func paddingCountsCharactersRatherThanBytes() {
        #expect(TextColumns.pad("é", to: 3) == "é  ")
        #expect(TextColumns.leftPad("👍", to: 3) == "  👍")
    }
}

@Suite struct POSIXQuoteTests {
    @Test func quoteWrapsPlainTextInSingleQuotes() {
        #expect(POSIXQuote.quote("ed") == "'ed'")
        #expect(POSIXQuote.quote("") == "''")
    }

    @Test func quoteEscapesEmbeddedApostrophes() {
        #expect(POSIXQuote.quote("o'brien") == "'o'\\''brien'")
        #expect(POSIXQuote.quote("'") == "''\\'''")
        #expect(POSIXQuote.quote("a'b'c") == "'a'\\''b'\\''c'")
    }

    @Test func quoteKeepsSpacesAndMetacharactersInsideTheQuotes() {
        #expect(POSIXQuote.quote("a b;rm") == "'a b;rm'")
        #expect(POSIXQuote.quote("$HOME") == "'$HOME'")
    }
}

@Suite struct DoubleQuotedTests {
    @Test func wrapAddsDoubleQuotes() {
        #expect(DoubleQuoted.wrap("title") == "\"title\"")
        #expect(DoubleQuoted.wrap("") == "\"\"")
    }

    @Test func wrapDoublesEmbeddedQuotes() {
        #expect(DoubleQuoted.wrap("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(DoubleQuoted.wrap("\"") == "\"\"\"\"")
    }
}

@Suite struct RepositoryURLTests {
    @Test func normalizedTrimsCaseAndATrailingGitSuffix() {
        #expect(
            RepositoryURL.normalized("  HTTPS://GitHub.com/Pulkitxm/Edith.git  ")
                == "https://github.com/pulkitxm/edith")
    }

    @Test func normalizedStripsRepeatedTrailingSlashes() {
        #expect(
            RepositoryURL.normalized("https://example.com/repo///") == "https://example.com/repo")
    }

    @Test func normalizedStripsOnlyTheFinalGitSuffix() {
        #expect(RepositoryURL.normalized("repo.git.git") == "repo.git")
        #expect(RepositoryURL.normalized("already") == "already")
    }
}

@Suite struct BlankTextTests {
    @Test func trimmedNonEmptyDropsNilEmptyAndWhitespace() {
        #expect(BlankText.trimmedNonEmpty(nil) == nil)
        #expect(BlankText.trimmedNonEmpty("") == nil)
        #expect(BlankText.trimmedNonEmpty(" \n\t") == nil)
    }

    @Test func trimmedNonEmptyReturnsTheTrimmedValue() {
        #expect(BlankText.trimmedNonEmpty("  edith  ") == "edith")
    }

    @Test func nonEmptyKeepsSurroundingWhitespace() {
        #expect(BlankText.nonEmpty(nil) == nil)
        #expect(BlankText.nonEmpty("") == nil)
        #expect(BlankText.nonEmpty("  edith  ") == "  edith  ")
    }
}

@Suite struct CompactDurationTests {
    @Test(arguments: [
        (0.0, "0s"),
        (59.9, "59s"),
        (60.0, "1m"),
        (3_599.0, "59m"),
        (3_600.0, "1h"),
        (86_399.0, "23h"),
        (86_400.0, "1d"),
        (172_800.0, "2d"),
    ])
    func textBucketsSeconds(seconds: Double, label: String) {
        #expect(CompactDuration.text(seconds) == label)
    }

    @Test func textTruncatesTowardZero() {
        #expect(CompactDuration.text(90.9) == "1m")
        #expect(CompactDuration.text(-5) == "-5s")
    }
}

@Suite struct CalendarDayTests {
    @Test func stampUsesTheProvidedCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(CalendarDay.stamp(date, calendar: calendar) == "2023-11-14")
    }

    @Test func stampPadsEachComponent() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 0)
        #expect(CalendarDay.stamp(date, calendar: calendar) == "1970-01-01")
    }
}

@Suite struct UnitIntervalTests {
    @Test func clampPinsValuesToZeroAndOne() {
        #expect(UnitInterval.clamp(-2) == 0)
        #expect(UnitInterval.clamp(0) == 0)
        #expect(UnitInterval.clamp(0.25) == 0.25)
        #expect(UnitInterval.clamp(1) == 1)
        #expect(UnitInterval.clamp(4) == 1)
    }
}

@Suite struct RGBHexTests {
    @Test func stringFormatsClampedBytes() {
        #expect(RGBHex.string(red: 255, green: 0, blue: 161) == "#FF00A1")
        #expect(RGBHex.string(red: 255, green: 0, blue: 161, uppercase: false) == "#ff00a1")
        #expect(RGBHex.string(red: -4, green: 300, blue: 15) == "#00FF0F")
    }

    @Test func stringRoundsUnitComponents() {
        #expect(RGBHex.string(red: 1, green: 0, blue: 0.5) == "#FF0080")
        #expect(RGBHex.string(red: -1.0, green: 2.0, blue: 0, uppercase: false) == "#00ff00")
    }
}
