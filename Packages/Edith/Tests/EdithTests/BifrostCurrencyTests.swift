import Foundation
import Testing

@testable import EdithKit

@Suite struct BifrostCurrencyTests {
    private let rates = BifrostRates(
        asOf: Date(timeIntervalSince1970: 1_789_500_000),
        rates: ["EUR": 1, "USD": 1.08, "INR": 95.9, "GBP": 0.85])

    private func parse(_ input: String) -> BifrostCurrencyConversion? {
        BifrostCurrencyParser.parse(input, rates: rates)
    }

    @Test(arguments: [
        "48k usd in inr", "48000 usd to inr", "convert 48k usd to rupees",
        "48k dollars in inr",
    ]) func readsMoneyTheWayPeopleWriteIt(input: String) {
        let conversion = parse(input)
        #expect(conversion?.source.code == "USD", "\(input)")
        #expect(conversion?.target.code == "INR", "\(input)")
        #expect(conversion.map { abs($0.value - 48_000) < 0.001 } == true, "\(input)")
    }

    @Test func convertsThroughTheBaseCurrency() throws {
        let conversion = try #require(parse("1 usd in inr"))
        #expect(abs(conversion.result - 95.9 / 1.08) < 0.0001)
    }

    @Test func aSymbolInFrontOfTheAmountCounts() throws {
        let conversion = try #require(parse("$20 in gbp"))
        #expect(conversion.source.code == "USD")
        #expect(conversion.value == 20)
    }

    @Test func withoutRatesThereIsNoAnswer() {
        #expect(BifrostCurrencyParser.parse("1 usd in inr", rates: nil) == nil)
    }

    @Test func anUnknownCurrencyIsNotAConversion() {
        #expect(parse("1 usd in dogecoin") == nil)
        #expect(parse("12 km in miles") == nil)
    }

    @Test func amountsCarryMagnitudeSuffixes() {
        #expect(BifrostCalculator.value(of: "48k") == 48_000)
        #expect(BifrostCalculator.value(of: "2.5m") == 2_500_000)
        #expect(BifrostCalculator.value(of: "1b") == 1_000_000_000)
        #expect(BifrostCalculator.value(of: "5km") == nil)
    }

    @Test func ratesRoundTripThroughTheirCache() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bifrost-rates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BifrostRateStore(location: directory.appendingPathComponent("rates.json"))

        #expect(store.load() == nil)
        store.save(rates)
        #expect(store.load() == rates)
        store.remove()
        #expect(store.load() == nil)
    }

    @Test func theFeedParsesTheReferenceDocument() throws {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01">
              <Cube><Cube time="2026-09-16">
                <Cube currency="USD" rate="1.0800"/>
                <Cube currency="INR" rate="95.9000"/>
              </Cube></Cube>
            </gesmes:Envelope>
            """
        let parsed = try #require(BifrostRateFeed.rates(from: Data(xml.utf8)))

        #expect(parsed.base == "EUR")
        #expect(parsed.rate(for: "EUR") == 1)
        #expect(parsed.rate(for: "USD") == 1.08)
        #expect(parsed.asOf == BifrostRateFeed.day(from: "2026-09-16"))
    }

    @Test func rubbishIsNotRates() {
        #expect(BifrostRateFeed.rates(from: Data("not xml".utf8)) == nil)
        #expect(BifrostRateFeed.rates(from: Data()) == nil)
    }

    @Test func stalenessIsMeasuredAgainstNow() {
        let now = Date(timeIntervalSince1970: 1_789_500_000)
        #expect(rates.isFresh(now: now))
        #expect(!rates.isFresh(now: now.addingTimeInterval(7 * 60 * 60)))
    }

    @Test func freshnessReadsInWords() {
        let now = Date(timeIntervalSince1970: 1_789_500_000)
        #expect(BifrostQuery.freshness(of: now, now: now) == "Updated just now")
        #expect(
            BifrostQuery.freshness(of: now.addingTimeInterval(-120), now: now)
                == "Updated 2 minutes ago")
    }

    @Test func theAnswerCardNamesBothSides() throws {
        let results = BifrostQuery.results(
            query: "48k usd in inr", applications: [], rates: rates,
            now: Date(timeIntervalSince1970: 1_789_500_000))
        let answer = try #require(results.first?.answer)

        #expect(answer.inputCaption == "American Dollars")
        #expect(answer.outputCaption == "Indian Rupees")
        #expect(answer.output.contains("\u{20B9}"))
        #expect(answer.footnote == "Updated just now")
    }

    @Test func everyCurrencyCodeIsUniqueAndResolvable() {
        let codes = BifrostCurrencyCatalog.currencies.map(\.code)
        #expect(Set(codes).count == codes.count)
        for currency in BifrostCurrencyCatalog.currencies {
            #expect(BifrostCurrencyCatalog.currency(currency.code)?.code == currency.code)
            #expect(BifrostCurrencyCatalog.currency(currency.name)?.code == currency.code)
        }
    }
}
