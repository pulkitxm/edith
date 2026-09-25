import Foundation

public struct BifrostPlaceholderContext: Sendable {
    public var query: String
    public var clipboard: String
    public var selection: String
    public var date: Date
    public var uuid: String
    public var locale: Locale
    public var timeZone: TimeZone

    public init(
        query: String = "", clipboard: String = "", selection: String = "",
        date: Date = Date(), uuid: String = UUID().uuidString,
        locale: Locale = Locale(identifier: "en_US_POSIX"), timeZone: TimeZone = .current
    ) {
        self.query = query
        self.clipboard = clipboard
        self.selection = selection
        self.date = date
        self.uuid = uuid
        self.locale = locale
        self.timeZone = timeZone
    }
}

public enum BifrostPlaceholderEncoding: String, CaseIterable, Sendable {
    case plain
    case urlQuery

    public func apply(_ value: String) -> String {
        switch self {
        case .plain: value
        case .urlQuery:
            value.addingPercentEncoding(withAllowedCharacters: Self.queryAllowed) ?? value
        }
    }

    private static let queryAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()
}

public enum BifrostPlaceholder {
    public static let query = "query"
    public static let argument = "argument"
    public static let clipboard = "clipboard"
    public static let selection = "selection"
    public static let date = "date"
    public static let time = "time"
    public static let uuid = "uuid"

    public static let names = [query, argument, clipboard, selection, date, time, uuid]

    public static func tokens(in template: String) -> [String] {
        var found: [String] = []
        for match in matches(in: template) where !found.contains(match.name) {
            found.append(match.name)
        }
        return found
    }

    public static func usesQuery(_ template: String) -> Bool {
        tokens(in: template).contains { $0 == query || $0 == argument }
    }

    public static func expand(
        _ template: String, context: BifrostPlaceholderContext,
        encoding: BifrostPlaceholderEncoding = .plain
    ) -> String {
        var output = ""
        var cursor = template.startIndex
        for match in matches(in: template) {
            output += template[cursor..<match.range.lowerBound]
            output += encoding.apply(value(for: match, context: context))
            cursor = match.range.upperBound
        }
        output += template[cursor...]
        return output
    }

    public static let shellVariablePrefix = "EDITH_BIFROST_"

    public static func shell(
        _ template: String, context: BifrostPlaceholderContext
    ) -> BifrostShellInvocation {
        var script = ""
        var environment: [String: String] = [:]
        var quoting = BifrostShellQuoting()
        var cursor = template.startIndex
        for (index, match) in matches(in: template).enumerated() {
            let literal = template[cursor..<match.range.lowerBound]
            quoting.advance(over: literal)
            script += literal
            let variable = shellVariablePrefix + String(index + 1)
            environment[variable] = value(for: match, context: context)
            script += quoting.reference(to: variable)
            cursor = match.range.upperBound
        }
        script += template[cursor...]
        return BifrostShellInvocation(script: script, environment: environment)
    }

    private struct Match {
        let name: String
        let argument: String?
        let range: Range<String.Index>
    }

    private static func matches(in template: String) -> [Match] {
        var found: [Match] = []
        var cursor = template.startIndex
        while let open = template[cursor...].firstIndex(of: "{") {
            guard let close = template[open...].firstIndex(of: "}") else { break }
            let inner = template[template.index(after: open)..<close]
            let pieces = inner.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(pieces.first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            if names.contains(name) {
                let argument = pieces.count > 1 ? String(pieces[1]) : nil
                found.append(
                    Match(
                        name: name, argument: argument,
                        range: open..<template.index(after: close)))
            }
            cursor = template.index(after: close)
        }
        return found
    }

    private static func value(for match: Match, context: BifrostPlaceholderContext) -> String {
        switch match.name {
        case query, argument: context.query
        case clipboard: context.clipboard
        case selection: context.selection.isEmpty ? context.clipboard : context.selection
        case uuid: context.uuid
        case date: formatted(context, format: match.argument ?? "yyyy-MM-dd")
        case time: formatted(context, format: match.argument ?? "HH:mm")
        default: ""
        }
    }

    private static func formatted(_ context: BifrostPlaceholderContext, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = context.locale
        formatter.timeZone = context.timeZone
        formatter.dateFormat = format
        return formatter.string(from: context.date)
    }
}

public struct BifrostShellInvocation: Equatable, Sendable {
    public var script: String
    public var environment: [String: String]

    public init(script: String, environment: [String: String] = [:]) {
        self.script = script
        self.environment = environment
    }
}

struct BifrostShellQuoting {
    private enum State {
        case bare
        case single
        case double
    }

    private var state = State.bare
    private var escaped = false

    mutating func advance(over text: Substring) {
        for character in text {
            if escaped {
                escaped = false
                continue
            }
            switch (state, character) {
            case (.single, "'"): state = .bare
            case (.single, _): break
            case (_, "\\"): escaped = true
            case (.bare, "'"): state = .single
            case (.bare, "\""): state = .double
            case (.double, "\""): state = .bare
            default: break
            }
        }
    }

    mutating func reference(to variable: String) -> String {
        escaped = false
        return switch state {
        case .bare: "\"${\(variable)}\""
        case .double: "${\(variable)}"
        case .single: "'\"${\(variable)}\"'"
        }
    }
}
