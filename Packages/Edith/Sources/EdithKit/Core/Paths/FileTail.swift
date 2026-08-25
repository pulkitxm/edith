import Darwin
import Foundation

public enum FileTail {
    public static func scanLinesReversed(
        _ url: URL, chunkBytes: Int = 64 * 1024, maxLineBytes: Int = 1024 * 1024,
        maxScanBytes: Int? = nil,
        shouldContinue: () -> Bool = { true },
        _ visit: (Data) -> Bool
    ) {
        guard chunkBytes > 0, maxLineBytes > 0 else { return }
        if let maxScanBytes, maxScanBytes <= 0 { return }
        guard let handle = regularFileHandle(url) else { return }
        defer { try? handle.close() }
        var offset = (try? handle.seekToEnd()) ?? 0
        let floor = maxScanBytes.map { offset > UInt64($0) ? offset - UInt64($0) : 0 } ?? 0
        var pending = Data()
        var discardingOversizedLine = false
        while offset > floor {
            guard shouldContinue() else { return }
            let count = min(UInt64(chunkBytes), offset - floor)
            offset -= count
            guard (try? handle.seek(toOffset: offset)) != nil,
                let chunk = try? handle.read(upToCount: Int(count))
            else { return }
            var block = chunk
            if !discardingOversizedLine { block.append(pending) }
            var upper = block.endIndex
            while let newline = block[..<upper].lastIndex(of: UInt8(ascii: "\n")) {
                guard shouldContinue() else { return }
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
        if floor == 0, shouldContinue(), !discardingOversizedLine, !pending.isEmpty {
            _ = visit(pending)
        }
    }

    public static func read(_ url: URL, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        guard let handle = regularFileHandle(url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: maxBytes) else { return "" }
        var text = String(decoding: data, as: UTF8.self)
        if offset > 0, let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }
        return text
    }

    private static func regularFileHandle(_ url: URL) -> FileHandle? {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            try? handle.close()
            return nil
        }
        return handle
    }
}
