import Foundation
import Testing

@testable import EdithKit

@Suite struct TextUtilitiesTests {
    @Test func URLCleanerRemovesGlobalHostAndCustomTracking() throws {
        let result = try #require(
            TextUtilitiesSupport.cleanURL(
                "https://www.youtube.com/watch?v=abc&utm_source=mail&si=share&ref=extra#part",
                customParameters: ["ref"]))
        #expect(result.value == "https://www.youtube.com/watch?v=abc#part")
        #expect(result.removedParameters == ["utm_source", "si", "ref"])
        #expect(TextUtilitiesSupport.cleanURL("plain text") == nil)
        #expect(
            TextUtilitiesSupport.cleanURL("https://example.com/path?keep=1")?.value
                == "https://example.com/path?keep=1")
    }

    @Test func plainTextPastePayloadRoundTripsEveryState() {
        for state in [
            PlainTextPasteState.pasted, .clipboardEmpty, .unavailable,
        ] {
            let payload = PlainTextPasteIPC.payload(requestID: "paste-1", state: state)
            #expect(payload[PlainTextPasteIPC.requestIDKey] as? String == "paste-1")
            #expect(PlainTextPasteIPC.state(from: payload) == state)
        }
    }

    @Test func snippetsMatchModesAndLongestTrigger() throws {
        let short = TextSnippet(name: "Mail", trigger: ";mail", replacement: "one")
        let long = TextSnippet(name: "Work mail", trigger: ";mailwork", replacement: "two")
        let immediate = TextSnippet(
            name: "Date", trigger: ";;date", replacement: "{{date}}", expansion: .immediate)
        #expect(
            TextUtilitiesSupport.match(
                buffer: "use ;mailwork ", expansion: .afterDelimiter, snippets: [short, long])
                == long)
        #expect(
            TextUtilitiesSupport.match(
                buffer: "prefix ;;date", expansion: .immediate, snippets: [immediate])
                == immediate)
        #expect(
            TextUtilitiesSupport.match(
                buffer: "prefix ;;date ", expansion: .afterDelimiter, snippets: [immediate])
                == nil)
    }

    @Test func variablesAndPersistenceRoundTrip() throws {
        let fixed = Date(timeIntervalSince1970: 0)
        let expanded = TextUtilitiesSupport.expand(
            "{{date}} {{time}} {{datetime}} {{date:MMM d}} {{clipboard}}",
            date: fixed, clipboard: "copied", locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(expanded == "1970-01-01 00:00 1970-01-01 00:00 Jan 1 copied")
        let snippets = [
            TextSnippet(
                name: "Signature", trigger: ";sig", replacement: "Thanks", folder: "Work",
                ignoresCase: true)
        ]
        #expect(TextUtilitiesSupport.decode(TextUtilitiesSupport.encode(snippets)) == snippets)
        #expect(TextUtilitiesSupport.sections(snippets).map(\.folder) == ["Work"])
    }

    @Test func autoClearRequiresTheSamePasteboardGenerationAndDeadline() {
        let copiedAt = Date(timeIntervalSince1970: 1_000)
        #expect(
            !TextUtilitiesSupport.shouldAutoClear(
                observedChangeCount: 2, currentChangeCount: 3, changedAt: copiedAt,
                now: copiedAt.addingTimeInterval(60), delay: 30))
        #expect(
            !TextUtilitiesSupport.shouldAutoClear(
                observedChangeCount: 2, currentChangeCount: 2, changedAt: copiedAt,
                now: copiedAt.addingTimeInterval(29), delay: 30))
        #expect(
            TextUtilitiesSupport.shouldAutoClear(
                observedChangeCount: 2, currentChangeCount: 2, changedAt: copiedAt,
                now: copiedAt.addingTimeInterval(30), delay: 30))
        #expect(TextUtilitiesSupport.clampedAutoClearDelay(0) == 5)
        #expect(TextUtilitiesSupport.clampedAutoClearDelay(10_000) == 3_600)
    }

    @Test func URLCleaningOnlyRewritesPlainURLPasteboards() {
        #expect(TextUtilitiesSupport.canRewritePasteboard(types: ["public.utf8-plain-text"]))
        #expect(
            TextUtilitiesSupport.canRewritePasteboard(
                types: ["public.utf8-plain-text", "public.url"]))
        #expect(
            !TextUtilitiesSupport.canRewritePasteboard(
                types: ["public.utf8-plain-text", "public.rtf"]))
        #expect(!TextUtilitiesSupport.canRewritePasteboard(types: []))
    }
}
