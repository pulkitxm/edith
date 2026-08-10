import Foundation

public enum TransferMarker: Equatable, Sendable {
    case pid(Int32)
    case scan(files: Int, bytes: Int64)
    case item(index: Int, exitStatus: Int32)

    public static let refusedIdenticalFile: Int32 = 200
}

public enum TransferMarkers {
    public static func parse(_ line: String) -> TransferMarker? {
        let fields = line.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 3, fields[0] == TransferCommands.markerPrefix else { return nil }
        switch fields[1] {
        case "PID":
            guard fields.count == 3, let pid = Int32(fields[2]) else { return nil }
            return .pid(pid)
        case "SCAN":
            guard fields.count == 4, let files = Int(fields[2]), let bytes = Int64(fields[3])
            else { return nil }
            return .scan(files: files, bytes: bytes)
        case "ITEM":
            guard fields.count == 4, let index = Int(fields[2]), let status = Int32(fields[3])
            else { return nil }
            return .item(index: index, exitStatus: status)
        default:
            return nil
        }
    }
}

public struct TransferLineSplitter: Sendable {
    private var fragment = ""

    public init() {}

    public mutating func receive(_ text: String) -> [String] {
        fragment += text
        var lines: [String] = []
        var current = ""
        var trailing = ""
        for character in fragment {
            if character == "\n" || character == "\r" {
                if !current.isEmpty { lines.append(current) }
                current = ""
                trailing = ""
            } else {
                current.append(character)
                trailing.append(character)
            }
        }
        fragment = trailing
        return lines
    }

    public mutating func flush() -> [String] {
        defer { fragment = "" }
        return fragment.isEmpty ? [] : [fragment]
    }
}

public enum EtaPhrasing {
    public static func bucket(seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        if seconds < 60 { return "Less than a minute" }
        let minutes = Int((seconds / 60).rounded())
        if minutes <= 1 { return "About a minute" }
        if minutes < 60 { return "About \(minutes) minutes" }
        let hours = Int((seconds / 3600).rounded())
        if hours <= 1 { return "About an hour" }
        if hours < 24 { return "About \(hours) hours" }
        let days = Int((seconds / 86400).rounded())
        return days <= 1 ? "About a day" : "About \(days) days"
    }
}
