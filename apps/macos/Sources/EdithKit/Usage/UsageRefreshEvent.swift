import Foundation

public enum UsageRefreshEvent: Sendable, Equatable {
    case phase(name: String, detail: String, seconds: Double)
    case note(String)
    case summary(label: String, value: String)
    case failure(String)
    case finished(seconds: Double)

    public var isTerminal: Bool {
        switch self {
        case .failure, .finished: return true
        case .phase, .note, .summary: return false
        }
    }

    public static func parse(_ line: String) -> UsageRefreshEvent? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard let kind = fields.first else { return nil }
        switch kind {
        case "phase" where fields.count >= 4:
            return .phase(
                name: fields[1], detail: fields[2], seconds: Double(fields[3]) ?? 0)
        case "note" where fields.count >= 2:
            return .note(fields[1])
        case "summary" where fields.count >= 3:
            return .summary(label: fields[1], value: fields[2])
        case "error" where fields.count >= 2:
            return .failure(fields[1])
        case "done" where fields.count >= 2:
            return .finished(seconds: Double(fields[1]) ?? 0)
        default:
            return nil
        }
    }

    public var wireLine: String {
        switch self {
        case let .phase(name, detail, seconds):
            return "phase\t\(name)\t\(detail)\t\(String(format: "%.2f", seconds))"
        case let .note(text):
            return "note\t\(text)"
        case let .summary(label, value):
            return "summary\t\(label)\t\(value)"
        case let .failure(text):
            return "error\t\(text)"
        case let .finished(seconds):
            return "done\t\(String(format: "%.2f", seconds))"
        }
    }
}

public enum UsageRefreshTranscript {
    public static let rule = String(repeating: "─", count: 52)

    public static func header(at date: Date) -> [String] {
        ["", "  EDITH · refresh usage · " + stamp.string(from: date), "  " + rule]
    }

    public static func lines(for event: UsageRefreshEvent) -> [String] {
        switch event {
        case let .phase(name, detail, seconds):
            let elapsed = String(format: "%.2f", seconds) + "s"
            return [
                "  ▸ " + pad(name, 10) + " " + pad(detail, 32) + " " + leftPad(elapsed, 7)
            ]
        case let .note(text):
            return ["  · " + text + "…"]
        case let .summary(label, value):
            return ["  ✓ " + pad(label, 9) + " " + value]
        case let .failure(text):
            return ["  ✖ " + text]
        case let .finished(seconds):
            return ["  ✓ done in " + String(format: "%.2f", seconds) + "s", ""]
        }
    }

    public static func render(_ events: [UsageRefreshEvent], startedAt: Date) -> String {
        var out = header(at: startedAt)
        var sawSummary = false
        for event in events {
            if case .summary = event, !sawSummary {
                sawSummary = true
                out.append("  " + rule)
            }
            out.append(contentsOf: lines(for: event))
        }
        return out.joined(separator: "\n") + "\n"
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private static func leftPad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }
}
