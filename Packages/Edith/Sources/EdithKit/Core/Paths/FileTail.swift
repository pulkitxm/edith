import Foundation

public enum FileTail {
    public static func scanLinesReversed(
        _ url: URL, chunkBytes: Int = 64 * 1024, _ visit: (Data) -> Bool
    ) {
        guard chunkBytes > 0, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var offset = (try? handle.seekToEnd()) ?? 0
        var pending = Data()
        while offset > 0 {
            let count = min(UInt64(chunkBytes), offset)
            offset -= count
            guard (try? handle.seek(toOffset: offset)) != nil,
                let chunk = try? handle.read(upToCount: Int(count))
            else { return }
            var block = chunk
            block.append(pending)
            var upper = block.endIndex
            while let newline = block[..<upper].lastIndex(of: UInt8(ascii: "\n")) {
                let start = block.index(after: newline)
                if start < upper, !visit(Data(block[start..<upper])) { return }
                upper = newline
            }
            pending = Data(block[..<upper])
        }
        if !pending.isEmpty { _ = visit(pending) }
    }

    public static func read(_ url: URL, maxBytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return "" }
        var text = String(decoding: data, as: UTF8.self)
        if offset > 0, let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }
        return text
    }
}
