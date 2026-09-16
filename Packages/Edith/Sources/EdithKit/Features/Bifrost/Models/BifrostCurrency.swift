import Foundation

public struct BifrostCurrency: Equatable, Sendable, Identifiable {
    public let code: String
    public let name: String
    public let aliases: [String]

    public var id: String { code }

    init(_ code: String, _ name: String, aliases: [String] = []) {
        self.code = code
        self.name = name
        self.aliases = aliases
    }
}

public enum BifrostCurrencyCatalog {
    public static let base = "EUR"

    public static let currencies: [BifrostCurrency] = [
        BifrostCurrency("EUR", "Euros", aliases: ["euro", "euros", "\u{20AC}"]),
        BifrostCurrency("USD", "American Dollars", aliases: ["dollar", "dollars", "$", "us$"]),
        BifrostCurrency("GBP", "British Pounds", aliases: ["pound", "pounds", "\u{A3}"]),
        BifrostCurrency("INR", "Indian Rupees", aliases: ["rupee", "rupees", "\u{20B9}"]),
        BifrostCurrency("JPY", "Japanese Yen", aliases: ["yen", "\u{A5}"]),
        BifrostCurrency("CNY", "Chinese Yuan", aliases: ["yuan", "renminbi", "rmb"]),
        BifrostCurrency("AUD", "Australian Dollars", aliases: ["aussie dollar"]),
        BifrostCurrency("CAD", "Canadian Dollars", aliases: []),
        BifrostCurrency("CHF", "Swiss Francs", aliases: ["franc", "francs"]),
        BifrostCurrency("SEK", "Swedish Krona", aliases: ["krona"]),
        BifrostCurrency("NOK", "Norwegian Krone", aliases: ["krone"]),
        BifrostCurrency("DKK", "Danish Krone", aliases: []),
        BifrostCurrency("PLN", "Polish Zloty", aliases: ["zloty"]),
        BifrostCurrency("CZK", "Czech Koruna", aliases: ["koruna"]),
        BifrostCurrency("HUF", "Hungarian Forint", aliases: ["forint"]),
        BifrostCurrency("TRY", "Turkish Lira", aliases: ["lira"]),
        BifrostCurrency("BRL", "Brazilian Real", aliases: ["real", "reais"]),
        BifrostCurrency("MXN", "Mexican Pesos", aliases: ["peso", "pesos"]),
        BifrostCurrency("ZAR", "South African Rand", aliases: ["rand"]),
        BifrostCurrency("SGD", "Singapore Dollars", aliases: []),
        BifrostCurrency("HKD", "Hong Kong Dollars", aliases: []),
        BifrostCurrency("NZD", "New Zealand Dollars", aliases: []),
        BifrostCurrency("KRW", "South Korean Won", aliases: ["won"]),
        BifrostCurrency("IDR", "Indonesian Rupiah", aliases: ["rupiah"]),
        BifrostCurrency("ILS", "Israeli Shekel", aliases: ["shekel"]),
        BifrostCurrency("PHP", "Philippine Pesos", aliases: []),
        BifrostCurrency("THB", "Thai Baht", aliases: ["baht"]),
        BifrostCurrency("MYR", "Malaysian Ringgit", aliases: ["ringgit"]),
        BifrostCurrency("RON", "Romanian Leu", aliases: ["leu"]),
        BifrostCurrency("BGN", "Bulgarian Lev", aliases: ["lev"]),
        BifrostCurrency("ISK", "Icelandic Krona", aliases: []),
    ]

    static let lookup: [String: BifrostCurrency] = {
        var table: [String: BifrostCurrency] = [:]
        for currency in currencies {
            table[currency.code.lowercased()] = currency
            table[currency.name.lowercased()] = currency
            for alias in currency.aliases { table[alias.lowercased()] = currency }
        }
        return table
    }()

    public static func currency(_ token: String) -> BifrostCurrency? {
        let normalized = token.trimmingCharacters(in: .whitespaces).lowercased()
        guard !normalized.isEmpty else { return nil }
        if let match = lookup[normalized] { return match }
        if normalized.hasSuffix("s") { return lookup[String(normalized.dropLast())] }
        return nil
    }

    public static func localeIdentifier(for code: String) -> String {
        switch code {
        case "INR": "en_IN"
        case "JPY": "ja_JP"
        case "KRW": "ko_KR"
        default: "en_US"
        }
    }

    public static func format(_ amount: Double, code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.locale = Locale(identifier: localeIdentifier(for: code))
        formatter.maximumFractionDigits = amount >= 100 ? 2 : 4
        return formatter.string(from: NSNumber(value: amount))
            ?? "\(BifrostNumberFormat.grouped(amount)) \(code)"
    }
}

public struct BifrostRates: Codable, Equatable, Sendable {
    public let base: String
    public let asOf: Date
    public let rates: [String: Double]

    public init(base: String = BifrostCurrencyCatalog.base, asOf: Date, rates: [String: Double]) {
        self.base = base
        self.asOf = asOf
        self.rates = rates
    }

    public func rate(for code: String) -> Double? {
        code == base ? 1 : rates[code]
    }

    public func convert(_ amount: Double, from source: String, to target: String) -> Double? {
        guard let from = rate(for: source), let to = rate(for: target), from > 0 else {
            return nil
        }
        let converted = amount / from * to
        return converted.isFinite ? converted : nil
    }

    public func isFresh(now: Date, maximumAge: TimeInterval = 6 * 60 * 60) -> Bool {
        now.timeIntervalSince(asOf) < maximumAge
    }
}
