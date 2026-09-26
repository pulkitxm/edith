import Foundation
import Testing

@testable import EdithDatabase

@Suite struct DatabaseBase64URLTests {
    @Test func encodeUsesTheURLAlphabetAndDropsPadding() {
        let data = Data([0xfb, 0xff, 0xbf])
        #expect(DatabaseBase64URL.encode(data) == "-_-_")
        #expect(!DatabaseBase64URL.encode(data).contains("="))
    }

    @Test func decodeRejectsTheStandardAlphabetAndEmptyInput() {
        #expect(DatabaseBase64URL.decode("") == nil)
        #expect(DatabaseBase64URL.decode("+/+") == nil)
        #expect(DatabaseBase64URL.decode("ab=c") == nil)
        #expect(DatabaseBase64URL.decode("a") == nil)
    }

    @Test func decodeRoundTripsUnpaddedURLText() {
        let samples = [
            Data([0x00]),
            Data([0xfb, 0xff, 0xbf]),
            Data("edith".utf8),
            Data(repeating: 0x7f, count: 32),
        ]
        for sample in samples {
            let encoded = DatabaseBase64URL.encode(sample)
            #expect(DatabaseBase64URL.decode(encoded) == sample)
        }
    }

    @Test func encodeOfEmptyDataStaysEmptyAndDoesNotDecode() {
        #expect(DatabaseBase64URL.encode(Data()) == "")
        #expect(DatabaseBase64URL.decode("") == nil)
    }
}
