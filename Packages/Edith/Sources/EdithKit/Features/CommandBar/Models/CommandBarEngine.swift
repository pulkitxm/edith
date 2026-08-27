import Foundation

public struct CommandBarCandidate: Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let keywords: [String]

    public init(id: String, title: String, subtitle: String, keywords: [String] = []) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
    }
}

public struct CommandBarUsageRecord: Codable, Equatable, Sendable {
    public let id: String
    public var count: Int
    public var lastUsed: Date

    public init(id: String, count: Int = 1, lastUsed: Date = Date()) {
        self.id = id
        self.count = count
        self.lastUsed = lastUsed
    }
}

public struct CommandBarUsage: Codable, Equatable, Sendable {
    public private(set) var records: [CommandBarUsageRecord]

    public init(records: [CommandBarUsageRecord] = []) {
        self.records = records
    }

    public mutating func record(_ id: String, at date: Date = Date()) {
        if let index = records.firstIndex(where: { $0.id == id }) {
            records[index].count = min(records[index].count + 1, 10_000)
            records[index].lastUsed = date
        } else {
            records.append(CommandBarUsageRecord(id: id, lastUsed: date))
        }
        records.sort { $0.lastUsed > $1.lastUsed }
        if records.count > 128 { records.removeSubrange(128...) }
    }

    public func score(for id: String, now: Date = Date()) -> Int {
        guard let record = records.first(where: { $0.id == id }) else { return 0 }
        let age = max(0, now.timeIntervalSince(record.lastUsed))
        let recency = max(0, 180 - Int(age / 86_400) * 12)
        return min(record.count, 30) * 8 + recency
    }
}

public enum CommandBarSearch {
    public static func rank(
        _ candidates: [CommandBarCandidate], query: String, usage: CommandBarUsage,
        limit: Int = 12, now: Date = Date()
    ) -> [CommandBarCandidate] {
        let query = normalized(query)
        return candidates.compactMap { candidate -> (CommandBarCandidate, Int)? in
            let match = matchScore(candidate, query: query)
            guard query.isEmpty || match > 0 else { return nil }
            return (candidate, match + usage.score(for: candidate.id, now: now))
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.title.localizedStandardCompare($1.0.title) == .orderedAscending
        }
        .prefix(max(0, limit))
        .map(\.0)
    }

    public static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func matchScore(_ candidate: CommandBarCandidate, query: String) -> Int {
        guard !query.isEmpty else { return 0 }
        let fields = [candidate.title, candidate.subtitle] + candidate.keywords
        return fields.enumerated().map { index, field in
            let value = normalized(field)
            let weight = index == 0 ? 400 : index == 1 ? 100 : 180
            if value == query { return 2_400 + weight }
            if value.hasPrefix(query) { return 1_600 + weight - value.count }
            if value.split(separator: " ").contains(where: { $0.hasPrefix(query) }) {
                return 1_200 + weight - value.count
            }
            if let range = value.range(of: query) {
                return 800 + weight - value.distance(from: value.startIndex, to: range.lowerBound)
            }
            guard isSubsequence(query, of: value) else { return 0 }
            return 300 + weight - max(0, value.count - query.count)
        }.max() ?? 0
    }

    private static func isSubsequence(_ query: String, of value: String) -> Bool {
        var index = query.startIndex
        for character in value where index < query.endIndex && character == query[index] {
            index = query.index(after: index)
        }
        return index == query.endIndex
    }
}

public struct CommandBarAnswer: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case calculation
        case conversion
    }

    public let kind: Kind
    public let formatted: String
    public let value: Double

    public init(kind: Kind, formatted: String, value: Double) {
        self.kind = kind
        self.formatted = formatted
        self.value = value
    }
}

public enum CommandBarEvaluator {
    public static func evaluate(_ input: String, locale: Locale = .current) -> CommandBarAnswer? {
        conversion(input, locale: locale) ?? calculation(input, locale: locale)
    }

    public static func calculation(
        _ input: String, locale: Locale = .current
    ) -> CommandBarAnswer? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 160, trimmed.contains(where: \.isNumber), !looksLikeDate(trimmed),
            let tokens = tokenize(trimmed, locale: locale),
            tokens.contains(where: \.isOperation)
        else { return nil }
        var parser = Parser(tokens: tokens)
        guard let value = parser.expression(), parser.finished, value.isFinite,
            let formatted = format(value, locale: locale)
        else { return nil }
        return CommandBarAnswer(kind: .calculation, formatted: formatted, value: value)
    }

    public static func conversion(
        _ input: String, locale: Locale = .current
    ) -> CommandBarAnswer? {
        let tokens = splitConversion(input)
        guard tokens.count == 4, conversionWords.contains(tokens[2]),
            let value = localizedNumber(tokens[0], locale: locale),
            let source = units[tokens[1]], let target = units[tokens[3]],
            source.family == target.family
        else { return nil }
        let converted = Measurement(value: value, unit: source.unit).converted(to: target.unit)
        guard converted.value.isFinite else { return nil }
        let number = format(converted.value, locale: locale) ?? String(converted.value)
        return CommandBarAnswer(
            kind: .conversion, formatted: "\(number) \(target.symbol)", value: converted.value)
    }

    private struct KnownUnit: @unchecked Sendable {
        let family: String
        let unit: Dimension
        let symbol: String
    }

    private static let conversionWords: Set<String> = ["in", "to"]

    private static let units: [String: KnownUnit] = {
        var result: [String: KnownUnit] = [:]
        func add(_ aliases: [String], family: String, unit: Dimension, symbol: String) {
            for alias in aliases {
                result[alias] = KnownUnit(family: family, unit: unit, symbol: symbol)
            }
        }
        add(
            ["mm", "millimeter", "millimeters"], family: "length", unit: UnitLength.millimeters,
            symbol: "mm")
        add(
            ["cm", "centimeter", "centimeters"], family: "length", unit: UnitLength.centimeters,
            symbol: "cm")
        add(
            ["m", "meter", "meters", "metre", "metres"], family: "length", unit: UnitLength.meters,
            symbol: "m")
        add(
            ["km", "kilometer", "kilometers"], family: "length", unit: UnitLength.kilometers,
            symbol: "km")
        add(["in", "inch", "inches"], family: "length", unit: UnitLength.inches, symbol: "in")
        add(["ft", "foot", "feet"], family: "length", unit: UnitLength.feet, symbol: "ft")
        add(["yd", "yard", "yards"], family: "length", unit: UnitLength.yards, symbol: "yd")
        add(["mi", "mile", "miles"], family: "length", unit: UnitLength.miles, symbol: "mi")
        add(
            ["mg", "milligram", "milligrams"], family: "mass", unit: UnitMass.milligrams,
            symbol: "mg")
        add(["g", "gram", "grams"], family: "mass", unit: UnitMass.grams, symbol: "g")
        add(
            ["kg", "kilogram", "kilograms"], family: "mass", unit: UnitMass.kilograms, symbol: "kg")
        add(["oz", "ounce", "ounces"], family: "mass", unit: UnitMass.ounces, symbol: "oz")
        add(["lb", "lbs", "pound", "pounds"], family: "mass", unit: UnitMass.pounds, symbol: "lb")
        add(
            ["c", "°c", "celsius"], family: "temperature", unit: UnitTemperature.celsius,
            symbol: "°C")
        add(
            ["f", "°f", "fahrenheit"], family: "temperature", unit: UnitTemperature.fahrenheit,
            symbol: "°F")
        add(["k", "kelvin"], family: "temperature", unit: UnitTemperature.kelvin, symbol: "K")
        add(
            ["b", "byte", "bytes"], family: "data", unit: UnitInformationStorage.bytes,
            symbol: "bytes")
        add(
            ["kb", "kilobyte", "kilobytes"], family: "data", unit: UnitInformationStorage.kilobytes,
            symbol: "KB")
        add(
            ["mb", "megabyte", "megabytes"], family: "data", unit: UnitInformationStorage.megabytes,
            symbol: "MB")
        add(
            ["gb", "gigabyte", "gigabytes"], family: "data", unit: UnitInformationStorage.gigabytes,
            symbol: "GB")
        add(
            ["tb", "terabyte", "terabytes"], family: "data", unit: UnitInformationStorage.terabytes,
            symbol: "TB")
        add(
            ["kib", "kibibyte", "kibibytes"], family: "data",
            unit: UnitInformationStorage.kibibytes, symbol: "KiB")
        add(
            ["mib", "mebibyte", "mebibytes"], family: "data",
            unit: UnitInformationStorage.mebibytes, symbol: "MiB")
        add(
            ["gib", "gibibyte", "gibibytes"], family: "data",
            unit: UnitInformationStorage.gibibytes, symbol: "GiB")
        add(
            ["ms", "millisecond", "milliseconds"], family: "duration",
            unit: UnitDuration.milliseconds, symbol: "ms")
        add(
            ["s", "sec", "second", "seconds"], family: "duration", unit: UnitDuration.seconds,
            symbol: "sec")
        add(
            ["min", "minute", "minutes"], family: "duration", unit: UnitDuration.minutes,
            symbol: "min")
        add(
            ["h", "hr", "hour", "hours"], family: "duration", unit: UnitDuration.hours, symbol: "hr"
        )
        add(
            ["ml", "milliliter", "milliliters"], family: "volume", unit: UnitVolume.milliliters,
            symbol: "mL")
        add(
            ["l", "liter", "liters", "litre", "litres"], family: "volume", unit: UnitVolume.liters,
            symbol: "L")
        add(["cup", "cups"], family: "volume", unit: UnitVolume.cups, symbol: "cups")
        add(
            ["gal", "gallon", "gallons"], family: "volume", unit: UnitVolume.gallons, symbol: "gal")
        return result
    }()

    private static func splitConversion(_ input: String) -> [String] {
        let normalized = CommandBarSearch.normalized(input)
        var result: [String] = []
        for token in normalized.split(separator: " ").map(String.init) {
            if let split = token.firstIndex(where: \.isLetter), split != token.startIndex {
                result.append(String(token[..<split]))
                result.append(String(token[split...]))
            } else {
                result.append(token)
            }
        }
        return result
    }

    private static func localizedNumber(_ value: String, locale: Locale) -> Double? {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        return formatter.number(from: value)?.doubleValue ?? Double(value)
    }

    private static func format(_ value: Double, locale: Locale) -> String? {
        let rounded = abs(value) < 1e-12 ? 0 : value
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = abs(rounded) >= 1e12 ? .scientific : .decimal
        formatter.maximumFractionDigits = 8
        formatter.maximumSignificantDigits = 12
        return formatter.string(from: NSNumber(value: rounded))
    }

    private static func looksLikeDate(_ input: String) -> Bool {
        for separator in ["/", ":"] {
            let pieces = input.split(separator: Character(separator))
            if (2...3).contains(pieces.count), pieces.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
                return true
            }
        }
        let pieces = input.split(separator: "-")
        return pieces.count == 3 && pieces.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    private enum Token: Equatable {
        case number(Double)
        case plus
        case minus
        case times
        case divide
        case power
        case percent
        case left
        case right

        var isOperation: Bool {
            switch self {
            case .plus, .minus, .times, .divide, .power, .percent: true
            case .number, .left, .right: false
            }
        }
    }

    private static func tokenize(_ input: String, locale: Locale) -> [Token]? {
        let decimal = Character(locale.decimalSeparator ?? ".")
        let grouping = Character(locale.groupingSeparator ?? ",")
        let characters = Array(input)
        var result: [Token] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace || character == "=" {
                index += 1
                continue
            }
            if character.isNumber || character == decimal {
                var raw = ""
                while index < characters.count,
                    characters[index].isNumber || characters[index] == decimal
                        || characters[index] == grouping
                {
                    raw.append(characters[index])
                    index += 1
                }
                let normalized = raw.replacingOccurrences(of: String(grouping), with: "")
                    .replacingOccurrences(of: String(decimal), with: ".")
                guard let number = Double(normalized) else { return nil }
                result.append(.number(number))
                continue
            }
            index += 1
            switch character {
            case "+": result.append(.plus)
            case "-", "−": result.append(.minus)
            case "*", "×", "x", "X": result.append(.times)
            case "/", "÷": result.append(.divide)
            case "^": result.append(.power)
            case "%": result.append(.percent)
            case "(", "[": result.append(.left)
            case ")", "]": result.append(.right)
            default: return nil
            }
        }
        return result.isEmpty ? nil : result
    }

    private struct Parser {
        let tokens: [Token]
        var index = 0
        var finished: Bool { index == tokens.count }

        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while let token = peek(), token == .plus || token == .minus {
                index += 1
                let startsWithPercent = nextTermIsPercent()
                guard let next = term() else { return nil }
                let delta = startsWithPercent ? value * next : next
                value = token == .plus ? value + delta : value - delta
            }
            return value
        }

        mutating func term() -> Double? {
            guard var value = factor() else { return nil }
            while let token = peek(), token == .times || token == .divide {
                index += 1
                guard let next = factor(), token != .divide || next != 0 else { return nil }
                value = token == .times ? value * next : value / next
            }
            return value
        }

        mutating func factor() -> Double? {
            if peek() == .plus || peek() == .minus {
                let negative = peek() == .minus
                index += 1
                guard let value = factor() else { return nil }
                return negative ? -value : value
            }
            guard var value = primary() else { return nil }
            if peek() == .power {
                index += 1
                guard let exponent = factor() else { return nil }
                value = pow(value, exponent)
            }
            if peek() == .percent {
                index += 1
                value /= 100
            }
            return value
        }

        mutating func primary() -> Double? {
            guard let token = peek() else { return nil }
            switch token {
            case .number(let value):
                index += 1
                return value
            case .left:
                index += 1
                guard let value = expression(), peek() == .right else { return nil }
                index += 1
                return value
            default:
                return nil
            }
        }

        func peek() -> Token? {
            index < tokens.count ? tokens[index] : nil
        }

        func nextTermIsPercent() -> Bool {
            var cursor = index
            if cursor < tokens.count, tokens[cursor] == .plus || tokens[cursor] == .minus {
                cursor += 1
            }
            guard cursor + 1 < tokens.count else { return false }
            if case .number = tokens[cursor] { return tokens[cursor + 1] == .percent }
            return false
        }
    }
}
