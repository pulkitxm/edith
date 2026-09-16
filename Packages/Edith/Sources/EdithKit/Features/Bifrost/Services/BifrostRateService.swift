import Foundation

public struct BifrostRateStore: Sendable {
    public static let fileName = "bifrost-rates.json"

    public let location: URL

    public init(location: URL) {
        self.location = location
    }

    public static var shared: BifrostRateStore {
        BifrostRateStore(location: DataRoot.caches.appendingPathComponent(fileName))
    }

    public func load(fileManager: FileManager = .default) -> BifrostRates? {
        guard let data = fileManager.contents(atPath: location.path),
            let decoded = try? JSONDecoder.bifrost.decode(BifrostRates.self, from: data),
            !decoded.rates.isEmpty
        else { return nil }
        return decoded
    }

    public func save(_ rates: BifrostRates, fileManager: FileManager = .default) {
        guard let data = try? JSONEncoder.bifrost.encode(rates) else { return }
        try? fileManager.createDirectory(
            at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: location, options: .atomic)
    }

    public func remove(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: location)
    }
}

public enum BifrostRateFeed {
    public static let endpoint = URL(
        string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!

    public static func rates(
        from data: Data, now: Date = Date()
    ) -> BifrostRates? {
        let parser = XMLParser(data: data)
        let collector = RateCollector()
        parser.delegate = collector
        guard parser.parse(), !collector.rates.isEmpty else { return nil }
        var rates = collector.rates
        rates[BifrostCurrencyCatalog.base] = 1
        return BifrostRates(asOf: collector.asOf ?? now, rates: rates)
    }

    public static func fetch(
        session: URLSession = .shared, now: @Sendable @escaping () -> Date = { Date() }
    ) async -> BifrostRates? {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 12
        request.httpMethod = "GET"
        guard let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return rates(from: data, now: now())
    }

    private final class RateCollector: NSObject, XMLParserDelegate {
        var rates: [String: Double] = [:]
        var asOf: Date?

        func parser(
            _ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String]
        ) {
            guard element == "Cube" else { return }
            if let time = attributes["time"] { asOf = BifrostRateFeed.day(from: time) }
            guard let code = attributes["currency"], let value = attributes["rate"],
                let rate = Double(value), rate > 0
            else { return }
            rates[code.uppercased()] = rate
        }
    }

    static func day(from text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}

public enum BifrostCurrencyParser {
    public static func parse(
        _ input: String, rates: BifrostRates?
    ) -> BifrostCurrencyConversion? {
        guard let rates else { return nil }
        let normalized = BifrostConversionParser.normalize(input)
        guard !normalized.isEmpty, normalized.count <= 200 else { return nil }
        for separator in BifrostConversionParser.separators {
            var searchStart = normalized.startIndex
            while let range = normalized.range(
                of: separator, range: searchStart..<normalized.endIndex)
            {
                let left = String(normalized[normalized.startIndex..<range.lowerBound])
                let right = String(normalized[range.upperBound...])
                if let conversion = build(left: left, right: right, rates: rates) {
                    return conversion
                }
                searchStart =
                    range.lowerBound < normalized.endIndex
                    ? normalized.index(after: range.lowerBound) : normalized.endIndex
            }
        }
        return nil
    }

    static func build(
        left: String, right: String, rates: BifrostRates
    ) -> BifrostCurrencyConversion? {
        guard let target = BifrostCurrencyCatalog.currency(right),
            let measurement = measurement(in: left),
            let result = rates.convert(
                measurement.value, from: measurement.currency.code, to: target.code)
        else { return nil }
        return BifrostCurrencyConversion(
            value: measurement.value, source: measurement.currency, target: target,
            result: result, asOf: rates.asOf)
    }

    static func measurement(in text: String) -> (value: Double, currency: BifrostCurrency)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let tokens = trimmed.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return nil }
        for count in stride(from: min(3, tokens.count), through: 1, by: -1) {
            let suffix = tokens.suffix(count).joined(separator: " ")
            let prefix = tokens.dropLast(count).joined(separator: " ")
            guard let currency = BifrostCurrencyCatalog.currency(suffix) else { continue }
            guard let value = amount(in: prefix) else { continue }
            return (value, currency)
        }
        guard let leading = BifrostCurrencyCatalog.currency(String(tokens[0].prefix(1))),
            let value = amount(in: String(tokens[0].dropFirst()))
        else { return nil }
        return (value, leading)
    }

    private static func amount(in text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return 1 }
        return BifrostCalculator.value(of: trimmed)
    }
}

public struct BifrostCurrencyConversion: Equatable, Sendable {
    public let value: Double
    public let source: BifrostCurrency
    public let target: BifrostCurrency
    public let result: Double
    public let asOf: Date

    public var display: String {
        BifrostCurrencyCatalog.format(result, code: target.code)
    }

    public var detail: String {
        let left = BifrostCurrencyCatalog.format(value, code: source.code)
        return "\(left) = \(display)"
    }

    public var copyText: String {
        BifrostNumberFormat.plain(result)
    }
}
