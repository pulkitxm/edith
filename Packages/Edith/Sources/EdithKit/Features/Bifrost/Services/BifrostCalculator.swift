import Foundation

public struct BifrostCalculation: Equatable, Sendable {
    public let expression: String
    public let value: Double
    public let display: String
    public let copyText: String

    public init(expression: String, value: Double) {
        self.expression = expression
        self.value = value
        display = BifrostNumberFormat.grouped(value)
        copyText = BifrostNumberFormat.plain(value)
    }
}

public enum BifrostCalculator {
    public static func evaluate(_ input: String) -> BifrostCalculation? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 200, let tokens = Tokenizer.tokens(in: trimmed) else { return nil }
        guard tokens.contains(where: \.isOperation) else { return nil }
        var parser = Parser(tokens: tokens)
        guard let value = parser.parseAll(), value.isFinite else { return nil }
        return BifrostCalculation(expression: trimmed, value: value)
    }

    public static func value(of input: String) -> Double? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200,
            let tokens = Tokenizer.tokens(in: trimmed)
        else { return nil }
        var parser = Parser(tokens: tokens)
        guard let value = parser.parseAll(), value.isFinite else { return nil }
        return value
    }

    static let magnitudes: [Character: Double] = ["k": 1_000, "m": 1_000_000, "b": 1_000_000_000]

    static let functions: Set<String> = [
        "sqrt", "cbrt", "abs", "round", "floor", "ceil", "ln", "log", "log2", "exp",
        "sin", "cos", "tan", "asin", "acos", "atan", "min", "max", "pow", "hypot",
    ]

    static let constants: [String: Double] = ["pi": .pi, "π": .pi, "tau": .pi * 2, "e": M_E]

    enum Token: Equatable {
        case number(Double)
        case symbol(String)
        case openParen
        case closeParen
        case comma
        case plus
        case minus
        case times
        case divide
        case power
        case percent

        var isOperation: Bool {
            switch self {
            case .number, .comma, .closeParen: false
            case .symbol(let name): !BifrostCalculator.constants.keys.contains(name)
            default: true
            }
        }
    }

    enum Tokenizer {
        static func tokens(in input: String) -> [Token]? {
            var tokens: [Token] = []
            let characters = Array(input.lowercased())
            var index = 0
            while index < characters.count {
                let character = characters[index]
                if character.isWhitespace || character == "," && !tokens.isEmpty {
                    if character == "," { tokens.append(.comma) }
                    index += 1
                    continue
                }
                if character.isNumber || character == "." {
                    guard let scanned = number(in: characters, from: index) else { return nil }
                    tokens.append(.number(scanned.value))
                    index = scanned.end
                    continue
                }
                if character.isLetter || character == "π" {
                    let start = index
                    while index < characters.count,
                        characters[index].isLetter || characters[index].isNumber
                            || characters[index] == "π"
                    {
                        index += 1
                    }
                    tokens.append(.symbol(String(characters[start..<index])))
                    continue
                }
                guard let token = operatorToken(character) else { return nil }
                tokens.append(token)
                index += 1
            }
            return tokens.isEmpty ? nil : tokens
        }

        private static func operatorToken(_ character: Character) -> Token? {
            switch character {
            case "(", "[": .openParen
            case ")", "]": .closeParen
            case "+": .plus
            case "-", "\u{2212}": .minus
            case "*", "\u{00D7}", "\u{22C5}": .times
            case "/", "\u{00F7}": .divide
            case "^": .power
            case "%": .percent
            case "_": nil
            default: nil
            }
        }

        private static func number(
            in characters: [Character], from start: Int
        ) -> (value: Double, end: Int)? {
            var index = start
            if characters[index] == "0", index + 1 < characters.count {
                let marker = characters[index + 1]
                if marker == "x" || marker == "b" {
                    let radix = marker == "x" ? 16 : 2
                    var digits = ""
                    index += 2
                    while index < characters.count,
                        characters[index].hexDigitValue.map({ $0 < radix }) == true
                    {
                        digits.append(characters[index])
                        index += 1
                    }
                    guard let parsed = UInt64(digits, radix: radix) else { return nil }
                    return (Double(parsed), index)
                }
            }
            var text = ""
            var seenDot = false
            while index < characters.count {
                let character = characters[index]
                if character.isNumber {
                    text.append(character)
                    index += 1
                    continue
                }
                if character == "." && !seenDot {
                    seenDot = true
                    text.append(character)
                    index += 1
                    continue
                }
                if character == "_" {
                    index += 1
                    continue
                }
                if character == "," && index + 3 < characters.count && !seenDot
                    && characters[(index + 1)...(index + 3)].allSatisfy(\.isNumber)
                {
                    index += 1
                    continue
                }
                if character == "e", index + 1 < characters.count,
                    characters[index + 1].isNumber || characters[index + 1] == "-"
                        || characters[index + 1] == "+"
                {
                    text.append(character)
                    index += 1
                    if characters[index] == "-" || characters[index] == "+" {
                        text.append(characters[index])
                        index += 1
                    }
                    while index < characters.count, characters[index].isNumber {
                        text.append(characters[index])
                        index += 1
                    }
                    break
                }
                break
            }
            guard let value = Double(text) else { return nil }
            guard index < characters.count,
                let scale = magnitudes[characters[index]],
                index + 1 >= characters.count || !characters[index + 1].isLetter
            else { return (value, index) }
            return (value * scale, index + 1)
        }
    }

    struct Value {
        let number: Double
        let isPercent: Bool

        var resolved: Double { isPercent ? number / 100 : number }
    }

    struct Parser {
        let tokens: [Token]
        var index = 0

        init(tokens: [Token]) {
            self.tokens = tokens
        }

        mutating func parseAll() -> Double? {
            guard let value = expression() else { return nil }
            guard index == tokens.count else { return nil }
            return value.resolved
        }

        private var current: Token? { index < tokens.count ? tokens[index] : nil }

        private mutating func expression() -> Value? {
            guard var left = term() else { return nil }
            while let token = current, token == .plus || token == .minus {
                index += 1
                guard let right = term() else { return nil }
                let sign: Double = token == .plus ? 1 : -1
                if right.isPercent, !left.isPercent {
                    left = Value(
                        number: left.number * (1 + sign * right.number / 100), isPercent: false)
                } else {
                    left = Value(
                        number: left.resolved + sign * right.resolved, isPercent: false)
                }
            }
            return left
        }

        private mutating func term() -> Value? {
            guard var left = unary() else { return nil }
            while let token = current {
                if token == .times || token == .divide {
                    index += 1
                    guard let right = unary() else { return nil }
                    let divisor = right.resolved
                    if token == .times {
                        left = Value(number: left.resolved * divisor, isPercent: false)
                    } else {
                        guard divisor != 0 else { return nil }
                        left = Value(number: left.resolved / divisor, isPercent: false)
                    }
                    continue
                }
                if case .symbol(let name) = token, name == "of" || name == "mod" {
                    index += 1
                    guard let right = unary() else { return nil }
                    left =
                        name == "of"
                        ? Value(number: left.resolved * right.resolved, isPercent: false)
                        : right.resolved == 0
                            ? Value(number: .nan, isPercent: false)
                            : Value(
                                number: left.resolved.truncatingRemainder(
                                    dividingBy: right.resolved), isPercent: false)
                    continue
                }
                break
            }
            return left
        }

        private mutating func unary() -> Value? {
            if let token = current, token == .minus || token == .plus {
                index += 1
                guard let value = unary() else { return nil }
                return token == .minus
                    ? Value(number: -value.number, isPercent: value.isPercent) : value
            }
            return postfix()
        }

        private mutating func postfix() -> Value? {
            guard var value = power() else { return nil }
            if current == .percent {
                index += 1
                value = Value(number: value.number, isPercent: true)
            }
            return value
        }

        private mutating func power() -> Value? {
            guard let base = primary() else { return nil }
            guard current == .power else { return base }
            index += 1
            guard let exponent = unary() else { return nil }
            return Value(number: pow(base.resolved, exponent.resolved), isPercent: false)
        }

        private mutating func primary() -> Value? {
            switch current {
            case .number(let value):
                index += 1
                return Value(number: value, isPercent: false)
            case .openParen:
                index += 1
                guard let value = expression(), current == .closeParen else { return nil }
                index += 1
                return Value(number: value.resolved, isPercent: false)
            case .symbol(let name):
                index += 1
                if let constant = BifrostCalculator.constants[name] {
                    return Value(number: constant, isPercent: false)
                }
                guard BifrostCalculator.functions.contains(name) else { return nil }
                guard let arguments = arguments() else { return nil }
                guard let value = BifrostCalculator.apply(name, arguments) else { return nil }
                return Value(number: value, isPercent: false)
            default:
                return nil
            }
        }

        private mutating func arguments() -> [Double]? {
            guard current == .openParen else { return nil }
            index += 1
            var values: [Double] = []
            if current == .closeParen {
                index += 1
                return values
            }
            while true {
                guard let value = expression() else { return nil }
                values.append(value.resolved)
                if current == .comma {
                    index += 1
                    continue
                }
                guard current == .closeParen else { return nil }
                index += 1
                return values
            }
        }
    }

    static func apply(_ name: String, _ arguments: [Double]) -> Double? {
        switch (name, arguments.count) {
        case ("sqrt", 1): arguments[0] < 0 ? nil : sqrt(arguments[0])
        case ("cbrt", 1): cbrt(arguments[0])
        case ("abs", 1): abs(arguments[0])
        case ("round", 1): arguments[0].rounded()
        case ("floor", 1): arguments[0].rounded(.down)
        case ("ceil", 1): arguments[0].rounded(.up)
        case ("ln", 1): arguments[0] <= 0 ? nil : log(arguments[0])
        case ("log", 1): arguments[0] <= 0 ? nil : log10(arguments[0])
        case ("log2", 1): arguments[0] <= 0 ? nil : log2(arguments[0])
        case ("exp", 1): exp(arguments[0])
        case ("sin", 1): sin(arguments[0])
        case ("cos", 1): cos(arguments[0])
        case ("tan", 1): tan(arguments[0])
        case ("asin", 1): asin(arguments[0])
        case ("acos", 1): acos(arguments[0])
        case ("atan", 1): atan(arguments[0])
        case ("min", 2): Swift.min(arguments[0], arguments[1])
        case ("max", 2): Swift.max(arguments[0], arguments[1])
        case ("pow", 2): pow(arguments[0], arguments[1])
        case ("hypot", 2): hypot(arguments[0], arguments[1])
        default: nil
        }
    }
}
