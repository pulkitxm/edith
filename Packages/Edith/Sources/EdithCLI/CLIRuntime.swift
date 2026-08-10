import Foundation

public struct CLIFailure: Error, CustomStringConvertible, Equatable {
    public enum Kind: Int32, Equatable, Sendable {
        case failure = 1
        case usage = 2
        case notFound = 3
        case unavailable = 4
    }

    public let kind: Kind
    public let message: String
    public let hint: String?

    public init(_ kind: Kind, _ message: String, hint: String? = nil) {
        self.kind = kind
        self.message = message
        self.hint = hint
    }

    public init(_ message: String, hint: String? = nil) {
        self.init(.failure, message, hint: hint)
    }

    public var description: String { message }

    public static func usage(_ message: String, hint: String? = nil) -> CLIFailure {
        CLIFailure(.usage, message, hint: hint)
    }

    public static func notFound(_ message: String, hint: String? = nil) -> CLIFailure {
        CLIFailure(.notFound, message, hint: hint)
    }

    public static func unavailable(_ message: String, hint: String? = nil) -> CLIFailure {
        CLIFailure(.unavailable, message, hint: hint)
    }
}

public enum ArgumentChecks {
    public static func nonNegative(_ value: Int, _ name: String) throws -> Int {
        guard value >= 0 else {
            throw CLIFailure.usage("\(name) cannot be negative", hint: "pass 0 or more")
        }
        return value
    }

    public static func positive(_ value: Int, _ name: String) throws -> Int {
        guard value > 0 else {
            throw CLIFailure.usage("\(name) must be greater than zero")
        }
        return value
    }

    public static func positive(_ value: Double, _ name: String) throws -> Double {
        guard value > 0, value.isFinite else {
            throw CLIFailure.usage("\(name) must be greater than zero")
        }
        return value
    }

    public static func fraction(_ value: Double, _ name: String) throws -> Double {
        guard (0...1).contains(value) else {
            throw CLIFailure.usage("\(name) must be between 0 and 1")
        }
        return value
    }
}

public enum CLIOut {
    nonisolated(unsafe) static var stdoutHandle = FileHandle.standardOutput
    nonisolated(unsafe) static var stderrHandle = FileHandle.standardError

    public static func out(_ text: String) {
        guard let data = (text + "\n").data(using: .utf8) else { return }
        stdoutHandle.write(data)
    }

    public static func raw(_ text: String) {
        guard !text.isEmpty, let data = text.data(using: .utf8) else { return }
        stdoutHandle.write(data)
    }

    public static func note(_ text: String) {
        guard let data = (text + "\n").data(using: .utf8) else { return }
        stderrHandle.write(data)
    }

    public static func rawError(_ text: String) {
        guard !text.isEmpty, let data = text.data(using: .utf8) else { return }
        stderrHandle.write(data)
    }

    public static func json(_ value: JSONValue) {
        out(JSONSerializer.string(value))
    }

    public static func report(_ failure: CLIFailure) {
        note(labelled("error: ", failure.message))
        if let hint = failure.hint { note(labelled("hint: ", hint)) }
    }

    public static func labelled(_ label: String, _ text: String) -> String {
        let lines =
            text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else {
            return label.trimmingCharacters(in: .whitespaces)
        }
        let indent = String(repeating: " ", count: label.count)
        return ([label + first] + lines.dropFirst().map { indent + $0 })
            .joined(separator: "\n")
    }
}

public enum TextTable {
    public static func render(headers: [String], rows: [[String]]) -> String {
        let titles = headers.map(oneLine)
        guard !rows.isEmpty else { return titles.joined(separator: "  ") }
        let cells = rows.map { $0.map(oneLine) }
        var widths = titles.map { $0.count }
        for row in cells {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], cell.count)
            }
        }
        var lines: [String] = [line(titles, widths)]
        for row in cells { lines.append(line(row, widths)) }
        return lines.joined(separator: "\n")
    }

    public static func oneLine(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n", "\r", "\t": out.append(" ")
            default:
                guard scalar.value >= 0x20, scalar.value != 0x7F else { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func line(_ cells: [String], _ widths: [Int]) -> String {
        var parts: [String] = []
        for (index, width) in widths.enumerated() {
            let cell = index < cells.count ? cells[index] : ""
            parts.append(index == widths.count - 1 ? cell : pad(cell, to: width))
        }
        return parts.joined(separator: "  ").trimmingTrailingSpaces()
    }

    private static func pad(_ cell: String, to width: Int) -> String {
        let missing = width - cell.count
        guard missing > 0 else { return cell }
        return cell + String(repeating: " ", count: missing)
    }
}

extension String {
    func trimmingTrailingSpaces() -> String {
        var text = self
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }
}
