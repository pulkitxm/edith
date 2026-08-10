import Foundation

public enum ClipboardIndex {
    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decode(_ text: String) -> [ClipboardEntry] {
        let decoder = decoder()
        var out: [ClipboardEntry] = []
        for line in text.split(separator: "\n") {
            guard let entry = try? decoder.decode(ClipboardEntry.self, from: Data(line.utf8))
            else { continue }
            out.append(entry)
        }
        return out
    }

    public static func encode(_ entries: [ClipboardEntry]) -> String {
        guard !entries.isEmpty else { return "" }
        let encoder = encoder()
        return
            entries
            .compactMap { entry in
                (try? encoder.encode(entry)).map { String(decoding: $0, as: UTF8.self) }
            }
            .joined(separator: "\n") + "\n"
    }

    public static func encodeLine(_ entry: ClipboardEntry) -> String? {
        (try? encoder().encode(entry)).map { String(decoding: $0, as: UTF8.self) + "\n" }
    }

    public static func applyRetention(
        _ entries: [ClipboardEntry],
        maxItems: Int,
        maxAge: TimeInterval?,
        now: Date = Date()
    ) -> [ClipboardEntry] {
        var kept = entries
        if let maxAge {
            let cutoff = now.addingTimeInterval(-maxAge)
            kept = kept.filter { $0.pinned || $0.lastCopiedAt >= cutoff }
        }
        let sorted = kept.sorted { $0.lastCopiedAt < $1.lastCopiedAt }
        var overflow = max(0, sorted.filter { !$0.pinned }.count - maxItems)
        guard overflow > 0 else { return sorted }
        var result: [ClipboardEntry] = []
        for entry in sorted {
            if !entry.pinned, overflow > 0 {
                overflow -= 1
                continue
            }
            result.append(entry)
        }
        return result
    }
}
