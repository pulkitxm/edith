import Foundation

public enum FileTail {
    public static func scanLinesReversed(
        _ url: URL, chunkBytes: Int = 64 * 1024, maxLineBytes: Int = 1024 * 1024,
        _ visit: (Data) -> Bool
    ) {
        guard chunkBytes > 0, maxLineBytes > 0,
            let handle = try? FileHandle(forReadingFrom: url)
        else { return }
        defer { try? handle.close() }
        var offset = (try? handle.seekToEnd()) ?? 0
        var pending = Data()
        var discardingOversizedLine = false
        while offset > 0 {
            let count = min(UInt64(chunkBytes), offset)
            offset -= count
            guard (try? handle.seek(toOffset: offset)) != nil,
                let chunk = try? handle.read(upToCount: Int(count))
            else { return }
            var block = chunk
            if !discardingOversizedLine { block.append(pending) }
            var upper = block.endIndex
            while let newline = block[..<upper].lastIndex(of: UInt8(ascii: "\n")) {
                let start = block.index(after: newline)
                if discardingOversizedLine {
                    discardingOversizedLine = false
                } else if start < upper {
                    let line = block[start..<upper]
                    if line.count <= maxLineBytes, !visit(Data(line)) { return }
                }
                upper = newline
            }
            if discardingOversizedLine {
                pending.removeAll(keepingCapacity: false)
            } else {
                pending = Data(block[..<upper])
                if pending.count > maxLineBytes {
                    pending.removeAll(keepingCapacity: false)
                    discardingOversizedLine = true
                }
            }
        }
        if !discardingOversizedLine, !pending.isEmpty { _ = visit(pending) }
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
