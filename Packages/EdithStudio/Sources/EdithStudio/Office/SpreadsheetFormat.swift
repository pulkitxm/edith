import Foundation

public enum SpreadsheetFormat {
    static let builtIn: [Int: String] = [
        0: "General", 1: "0", 2: "0.00", 3: "#,##0", 4: "#,##0.00",
        5: "\"$\"#,##0_);(\"$\"#,##0)", 6: "\"$\"#,##0_);[Red](\"$\"#,##0)",
        7: "\"$\"#,##0.00_);(\"$\"#,##0.00)", 8: "\"$\"#,##0.00_);[Red](\"$\"#,##0.00)",
        9: "0%", 10: "0.00%", 11: "0.00E+00", 12: "# ?/?", 13: "# ??/??", 14: "yyyy-mm-dd",
        15: "d-mmm-yy", 16: "d-mmm", 17: "mmm-yy", 18: "h:mm AM/PM", 19: "h:mm:ss AM/PM",
        20: "h:mm", 21: "h:mm:ss", 22: "yyyy-mm-dd hh:mm", 37: "#,##0 ;(#,##0)",
        38: "#,##0 ;[Red](#,##0)", 39: "#,##0.00;(#,##0.00)", 40: "#,##0.00;[Red](#,##0.00)",
        41: "_(* #,##0_);_(* (#,##0);_(* \"-\"_);_(@_)",
        42: "_(\"$\"* #,##0_);_(\"$\"* (#,##0);_(\"$\"* \"-\"_);_(@_)",
        43: "_(* #,##0.00_);_(* (#,##0.00);_(* \"-\"??_);_(@_)",
        44: "_(\"$\"* #,##0.00_);_(\"$\"* (#,##0.00);_(\"$\"* \"-\"??_);_(@_)",
        45: "mm:ss", 46: "[h]:mm:ss", 47: "mm:ss.0", 48: "##0.0E+0", 49: "@",
    ]

    public static func code(for id: Int, custom: [Int: String]) -> String {
        if let code = custom[id] { return code }
        if let code = builtIn[id] { return code }
        if (27...36).contains(id) || (50...58).contains(id) { return "yyyy-mm-dd" }
        return "General"
    }

    enum Token: Equatable {
        case literal(String)
        case digit(Character)
        case point
        case comma
        case percent
        case exponent(String)
        case date(String)
        case meridiem(String)
        case elapsed(String)
        case general
        case text
    }

    public static func display(_ value: Double, code: String, date1904: Bool = false) -> String {
        guard value.isFinite else { return general(value) }
        let sections = split(code)
        guard !sections.isEmpty else { return general(value) }
        var section = sections[0]
        var number = value
        var signed = true
        if sections.count >= 3, value == 0 {
            section = sections[2]
            signed = false
        } else if sections.count >= 2, value < 0 {
            section = sections[1]
            number = abs(value)
            signed = false
        }
        let tokens = tokenize(section)
        if tokens.contains(where: {
            if case .date = $0 { return true }
            if case .elapsed = $0 { return true }
            return false
        }) {
            return date(value, tokens: tokens, date1904: date1904)
        }
        if tokens.contains(.general) || tokens == [.text] {
            return tokens.map { token -> String in
                switch token {
                case .general, .text: return general(signed ? number : abs(number))
                case let .literal(text): return text
                default: return ""
                }
            }.joined()
        }
        guard tokens.contains(where: { if case .digit = $0 { return true } else { return false } })
        else {
            return tokens.map { token -> String in
                if case let .literal(text) = token { return text }
                return ""
            }.joined()
        }
        return numeric(number, tokens: tokens, signed: signed)
    }

    static func general(_ value: Double) -> String {
        guard value.isFinite else { return value.isNaN ? "#NUM!" : "#DIV/0!" }
        if value.rounded() == value, abs(value) < 1e15 { return String(Int64(value)) }
        let magnitude = abs(value)
        if magnitude >= 1e11 || magnitude < 1e-9 {
            let text = String(format: "%.5E", value)
            guard let range = text.range(of: "E") else { return text }
            var mantissa = String(text[..<range.lowerBound])
            while mantissa.contains("."), mantissa.hasSuffix("0") { mantissa.removeLast() }
            if mantissa.hasSuffix(".") { mantissa.removeLast() }
            return mantissa + text[range.lowerBound...]
        }
        let digits = max(0, 10 - Int(floor(log10(magnitude))) - 1)
        var text = String(format: "%.\(min(digits, 15))f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }

    static func split(_ code: String) -> [String] {
        var sections: [String] = []
        var current = ""
        var quoted = false
        var bracket = false
        var escape = false
        for character in code {
            if escape {
                current.append(character)
                escape = false
                continue
            }
            switch character {
            case "\\" where !quoted:
                escape = true
                current.append(character)
            case "\"":
                quoted.toggle()
                current.append(character)
            case "[" where !quoted:
                bracket = true
                current.append(character)
            case "]" where !quoted:
                bracket = false
                current.append(character)
            case ";" where !quoted && !bracket:
                sections.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        sections.append(current)
        return sections
    }

    static func tokenize(_ section: String) -> [Token] {
        var tokens: [Token] = []
        let characters = Array(section)
        var index = 0
        func literal(_ text: String) {
            if case let .literal(previous) = tokens.last {
                tokens[tokens.count - 1] = .literal(previous + text)
            } else {
                tokens.append(.literal(text))
            }
        }
        while index < characters.count {
            let character = characters[index]
            let lower = Character(character.lowercased())
            switch character {
            case "\"":
                var text = ""
                index += 1
                while index < characters.count, characters[index] != "\"" {
                    text.append(characters[index])
                    index += 1
                }
                literal(text)
            case "\\":
                index += 1
                if index < characters.count { literal(String(characters[index])) }
            case "_", "*":
                index += 1
            case "[":
                var content = ""
                index += 1
                while index < characters.count, characters[index] != "]" {
                    content.append(characters[index])
                    index += 1
                }
                let lowered = content.lowercased()
                if content.hasPrefix("$") {
                    let symbol = content.dropFirst().split(separator: "-", maxSplits: 1).first
                    literal(symbol.map(String.init) ?? "")
                } else if !lowered.isEmpty, lowered.allSatisfy({ "hms".contains($0) }),
                    Set(lowered).count == 1
                {
                    tokens.append(.elapsed(lowered))
                }
            case "0", "#", "?":
                tokens.append(.digit(character))
            case ".":
                tokens.append(.point)
            case ",":
                tokens.append(.comma)
            case "%":
                tokens.append(.percent)
            case "E",
                "e"
            where index + 1 < characters.count && "+-".contains(characters[index + 1]):
                tokens.append(.exponent(String(characters[index + 1])))
                index += 1
            case "@":
                tokens.append(.text)
            default:
                let rest = String(characters[index...]).lowercased()
                if rest.hasPrefix("general") {
                    tokens.append(.general)
                    index += 7
                    continue
                }
                if rest.hasPrefix("am/pm") {
                    tokens.append(.meridiem("AM/PM"))
                    index += 5
                    continue
                }
                if rest.hasPrefix("a/p") {
                    tokens.append(.meridiem("A/P"))
                    index += 3
                    continue
                }
                if "ymdhs".contains(lower) {
                    var run = String(lower)
                    while index + 1 < characters.count,
                        Character(characters[index + 1].lowercased()) == lower
                    {
                        run.append(lower)
                        index += 1
                    }
                    tokens.append(.date(run))
                } else {
                    literal(String(character))
                }
            }
            index += 1
        }
        return tokens
    }

    static func numeric(_ value: Double, tokens: [Token], signed: Bool) -> String {
        var number = value
        let percents = tokens.filter { $0 == .percent }.count
        for _ in 0..<percents { number *= 100 }
        guard
            let firstDigit = tokens.firstIndex(where: {
                if case .digit = $0 { return true } else { return false }
            })
        else { return general(value) }
        let exponentIndex = tokens.firstIndex {
            if case .exponent = $0 { return true } else { return false }
        }
        let lastMantissa =
            tokens[..<(exponentIndex ?? tokens.count)].lastIndex {
                if case .digit = $0 { return true } else { return false }
            } ?? firstDigit
        let pointIndex = tokens[firstDigit...lastMantissa].firstIndex(of: .point)
        let integerTokens = Array(tokens[firstDigit..<(pointIndex ?? (lastMantissa + 1))])
        let fractionTokens =
            pointIndex.map { Array(tokens[($0 + 1)...lastMantissa]) } ?? []
        if let slash = tokens[firstDigit...lastMantissa].firstIndex(where: {
            if case let .literal(text) = $0 { return text.contains("/") }
            return false
        }) {
            return fraction(
                number, tokens: tokens, slash: slash, last: lastMantissa, signed: signed)
        }
        var scaling = 0
        var trailing = lastMantissa + 1
        while trailing < tokens.count, tokens[trailing] == .comma {
            scaling += 1
            trailing += 1
        }
        for _ in 0..<scaling { number /= 1000 }
        let integerPlaceholders = integerTokens.compactMap { token -> Character? in
            if case let .digit(value) = token { return value }
            return nil
        }
        let fractionPlaceholders = fractionTokens.compactMap { token -> Character? in
            if case let .digit(value) = token { return value }
            return nil
        }
        let grouping = integerTokens.contains(.comma)
        let negative = number < 0 && signed
        number = abs(number)
        var exponentText = ""
        if let exponentIndex, case let .exponent(sign) = tokens[exponentIndex] {
            var power = number == 0 ? 0 : Int(floor(log10(number)))
            let width = max(1, integerPlaceholders.count)
            if width > 1 { power = Int(floor(Double(power) / Double(width))) * width }
            number /= pow(10, Double(power))
            let exponentDigits = tokens[(exponentIndex + 1)...].prefix {
                if case .digit = $0 { return true } else { return false }
            }.count
            let magnitude = String(abs(power))
            let padded =
                String(repeating: "0", count: max(0, exponentDigits - magnitude.count)) + magnitude
            exponentText = "E" + (power < 0 ? "-" : (sign == "+" ? "+" : "")) + padded
        }
        let rounded = round(number, places: fractionPlaceholders.count)
        let parts = rounded.split(separator: ".", omittingEmptySubsequences: false)
        var integerDigits = String(parts.first ?? "0")
        var fractionDigits = parts.count > 1 ? String(parts[1]) : ""
        fractionDigits += String(
            repeating: "0", count: max(0, fractionPlaceholders.count - fractionDigits.count))
        let minimum = integerPlaceholders.filter { $0 == "0" }.count
        if integerDigits == "0", minimum == 0 { integerDigits = "" }
        if integerDigits.count < minimum {
            integerDigits =
                String(repeating: "0", count: minimum - integerDigits.count) + integerDigits
        }
        if grouping, integerDigits.count > 3 {
            var grouped = ""
            for (offset, digit) in integerDigits.reversed().enumerated() {
                if offset > 0, offset % 3 == 0 { grouped.append(",") }
                grouped.append(digit)
            }
            integerDigits = String(grouped.reversed())
        }
        var fraction = Array(fractionDigits)
        var placeholder = fractionPlaceholders.count - 1
        while placeholder >= 0, fractionPlaceholders[placeholder] != "0", fraction.last == "0" {
            fraction.removeLast()
            placeholder -= 1
        }
        var result = ""
        var wroteNumber = false
        for (index, token) in tokens.enumerated() {
            if index >= firstDigit && index <= lastMantissa {
                if !wroteNumber {
                    result += integerDigits
                    if pointIndex != nil { result += "." + String(fraction) }
                    wroteNumber = true
                }
                continue
            }
            if let exponentIndex, index >= exponentIndex {
                if index == exponentIndex { result += exponentText }
                if case let .literal(text) = token, index > exponentIndex {
                    let digits = tokens[(exponentIndex + 1)...].prefix {
                        if case .digit = $0 { return true } else { return false }
                    }.count
                    if index > exponentIndex + digits { result += text }
                }
                continue
            }
            switch token {
            case let .literal(text): result += text
            case .percent: result += "%"
            default: continue
            }
        }
        let isZero =
            !integerDigits.contains(where: { $0 != "0" && $0 != "," })
            && !fraction.contains(where: { $0 != "0" })
        return (negative && !isZero ? "-" : "") + result
    }

    static func fraction(
        _ value: Double, tokens: [Token], slash: Int, last: Int, signed: Bool
    ) -> String {
        let denominatorDigits = tokens[(slash + 1)...last].filter {
            if case .digit = $0 { return true } else { return false }
        }.count
        let limit = max(1, Int(pow(10, Double(max(1, denominatorDigits)))) - 1)
        let magnitude = abs(value)
        var whole = floor(magnitude)
        let remainder = magnitude - whole
        var best = (numerator: 0, denominator: 1, error: remainder)
        for denominator in 1...limit {
            let numerator = Int((remainder * Double(denominator)).rounded())
            let error = abs(remainder - Double(numerator) / Double(denominator))
            if error < best.error - 1e-12 { best = (numerator, denominator, error) }
        }
        if best.numerator == best.denominator {
            whole += 1
            best.numerator = 0
        }
        let hasWhole = tokens[..<slash].contains { token in
            if case .literal(let text) = token { return text.contains(" ") }
            return false
        }
        var text: String
        if best.numerator == 0 {
            text = String(Int64(whole))
        } else if hasWhole && whole > 0 {
            text = "\(Int64(whole)) \(best.numerator)/\(best.denominator)"
        } else if hasWhole {
            text = "\(best.numerator)/\(best.denominator)"
        } else {
            text =
                "\(Int64(whole) * Int64(best.denominator) + Int64(best.numerator))/\(best.denominator)"
        }
        if value < 0 && signed { text = "-" + text }
        return text
    }

    static func round(_ value: Double, places: Int) -> String {
        guard
            var decimal = Decimal(
                string: String(format: "%.15g", value), locale: Locale(identifier: "en_US_POSIX"))
        else { return String(format: "%.\(places)f", value) }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, places, .plain)
        let text = NSDecimalNumber(decimal: rounded).description(
            withLocale: Locale(identifier: "en_US_POSIX"))
        if text.contains("e") || text.contains("E") {
            return String(format: "%.\(places)f", NSDecimalNumber(decimal: rounded).doubleValue)
        }
        return text
    }

    static let months = [
        "January", "February", "March", "April", "May", "June", "July", "August", "September",
        "October", "November", "December",
    ]
    static let weekdays = [
        "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
    ]

    public static func components(_ serial: Double, date1904: Bool) -> DateComponents? {
        guard serial.isFinite, serial > -1, serial < 2_958_466 else { return nil }
        let milliseconds = Int64((serial * 86_400_000).rounded())
        let days = Int(milliseconds / 86_400_000)
        let remainder = Int(milliseconds % 86_400_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let origin: DateComponents
        if date1904 {
            origin = DateComponents(year: 1904, month: 1, day: 1)
        } else if days < 61 {
            origin = DateComponents(year: 1899, month: 12, day: 31)
        } else {
            origin = DateComponents(year: 1899, month: 12, day: 30)
        }
        guard let start = calendar.date(from: origin),
            let day = calendar.date(byAdding: .day, value: days, to: start)
        else { return nil }
        var result = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
        result.hour = remainder / 3_600_000
        result.minute = remainder / 60_000 % 60
        result.second = remainder / 1000 % 60
        result.nanosecond = remainder % 1000 * 1_000_000
        return result
    }

    static func date(_ serial: Double, tokens: [Token], date1904: Bool) -> String {
        guard let parts = components(serial, date1904: date1904) else { return general(serial) }
        let twelve = tokens.contains {
            if case .meridiem = $0 { return true } else { return false }
        }
        let hour = parts.hour ?? 0
        let milliseconds = (parts.nanosecond ?? 0) / 1_000_000
        var result = ""
        for (index, token) in tokens.enumerated() {
            switch token {
            case let .literal(text): result += text
            case let .date(run):
                let letter = run.first ?? "d"
                let count = run.count
                switch letter {
                case "y":
                    let year = parts.year ?? 1900
                    result += count <= 2 ? String(format: "%02d", year % 100) : String(year)
                case "m":
                    if isMinute(index, tokens) {
                        result +=
                            count >= 2
                            ? String(format: "%02d", parts.minute ?? 0) : "\(parts.minute ?? 0)"
                    } else {
                        let month = parts.month ?? 1
                        switch count {
                        case 1: result += "\(month)"
                        case 2: result += String(format: "%02d", month)
                        case 3: result += String(months[month - 1].prefix(3))
                        case 5: result += String(months[month - 1].prefix(1))
                        default: result += months[month - 1]
                        }
                    }
                case "d":
                    let day = parts.day ?? 1
                    let weekday = weekdays[((parts.weekday ?? 1) - 1) % 7]
                    switch count {
                    case 1: result += "\(day)"
                    case 2: result += String(format: "%02d", day)
                    case 3: result += String(weekday.prefix(3))
                    default: result += weekday
                    }
                case "h":
                    let shown = twelve ? (hour % 12 == 0 ? 12 : hour % 12) : hour
                    result += count >= 2 ? String(format: "%02d", shown) : "\(shown)"
                case "s":
                    result +=
                        count >= 2
                        ? String(format: "%02d", parts.second ?? 0) : "\(parts.second ?? 0)"
                    if index + 2 < tokens.count, tokens[index + 1] == .point,
                        case .digit = tokens[index + 2]
                    {
                        let places = tokens[(index + 2)...].prefix {
                            if case .digit = $0 { return true } else { return false }
                        }.count
                        let fraction = String(format: "%03d", milliseconds).prefix(min(places, 3))
                        result += "." + fraction
                    }
                default: continue
                }
            case let .meridiem(style):
                let morning = hour < 12
                result += style == "A/P" ? (morning ? "A" : "P") : (morning ? "AM" : "PM")
            case let .elapsed(unit):
                let total = serial * 86_400
                let value: Double
                switch unit.first {
                case "h": value = floor(total / 3600)
                case "m": value = floor(total / 60)
                default: value = floor(total)
                }
                let text = String(Int64(value))
                result += String(repeating: "0", count: max(0, unit.count - text.count)) + text
            case .point:
                if index > 0, case let .date(run) = tokens[index - 1], run.first == "s" { continue }
                result += "."
            case .digit:
                if tokens[..<index].contains(where: { $0 == .point }) { continue }
                result += "0"
            case .percent: result += "%"
            case .comma: result += ","
            default: continue
            }
        }
        return result
    }

    static func isMinute(_ index: Int, _ tokens: [Token]) -> Bool {
        var cursor = index - 1
        while cursor >= 0 {
            switch tokens[cursor] {
            case let .date(run): if run.first == "h" { return true } else { cursor = -1 }
            case let .elapsed(unit): if unit.first == "h" { return true } else { cursor = -1 }
            case .literal: cursor -= 1
            default: cursor = -1
            }
        }
        cursor = index + 1
        while cursor < tokens.count {
            switch tokens[cursor] {
            case let .date(run): return run.first == "s"
            case let .elapsed(unit): return unit.first == "s"
            case .literal: cursor += 1
            default: return false
            }
        }
        return false
    }
}
