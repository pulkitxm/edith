import Foundation

public struct CommandBarResultShortcut: Codable, Equatable, Sendable {
    public let keyCode: Int
    public let modifiers: Int
    public let label: String

    public init(keyCode: Int, modifiers: Int, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }
}

public enum CommandBarPreferences {
    public static let maximumHiddenResults = 200
    public static let maximumPins = 30
    public static let maximumShortcuts = 9

    public static func decodeList(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        var seen = Set<String>()
        return raw.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public static func encodeList(_ values: [String]) -> String {
        decodeList(values.joined(separator: "\n")).joined(separator: "\n")
    }

    public static func decodeSet(_ raw: String?) -> Set<String> {
        Set(decodeList(raw))
    }

    public static func togglingPin(_ id: String, in pins: [String]) -> [String] {
        var next = pins
        if let index = next.firstIndex(of: id) {
            next.remove(at: index)
        } else {
            next.append(id)
            if next.count > maximumPins { next.removeFirst(next.count - maximumPins) }
        }
        return next
    }

    public static func togglingHidden(_ id: String, in hidden: Set<String>) -> Set<String> {
        var next = hidden
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        return next
    }

    public static func decodeShortcuts(_ raw: String?) -> [String: CommandBarResultShortcut] {
        guard let raw, let data = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(
                [String: CommandBarResultShortcut].self, from: data)
        else { return [:] }
        return decoded
    }

    public static func encodeShortcuts(
        _ shortcuts: [String: CommandBarResultShortcut]
    ) -> String? {
        guard let data = try? JSONEncoder().encode(shortcuts) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func assigning(
        _ shortcut: CommandBarResultShortcut?, to id: String,
        in shortcuts: [String: CommandBarResultShortcut]
    ) -> [String: CommandBarResultShortcut] {
        var next = shortcuts
        guard let shortcut else {
            next.removeValue(forKey: id)
            return next
        }
        for key in next.keys where next[key] == shortcut && key != id {
            next.removeValue(forKey: key)
        }
        guard next[id] != nil || next.count < maximumShortcuts else { return next }
        next[id] = shortcut
        return next
    }

    public static func rankBias(id: String, pins: [String], sourceBias: Int = 0) -> Int {
        sourceBias + (pins.contains(id) ? 60 : 0)
    }
}
