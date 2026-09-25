import Foundation

enum LevelDBReaderError: Error, Equatable {
    case missingDirectory, badTable
}

struct LevelDBEntry: Equatable, Sendable {
    let key: Data
    let value: Data?
    let sequence: UInt64
}

enum LevelDBReader {
    static func liveEntries(inDirectory directory: URL) throws -> [Data: Data] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { throw LevelDBReaderError.missingDirectory }
        let files = try manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        var winners: [Data: LevelDBEntry] = [:]
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let suffix = file.pathExtension
            guard ["log", "ldb", "sst"].contains(suffix),
                let data = try? Data(contentsOf: file)
            else { continue }
            let entries: [LevelDBEntry]
            if suffix == "log" {
                entries = logRecords(data).flatMap { batchEntries($0) }
            } else {
                guard let parsed = try? tableEntries(data) else { continue }
                entries = parsed
            }
            for entry in entries {
                if let current = winners[entry.key], current.sequence >= entry.sequence { continue }
                winners[entry.key] = entry
            }
        }
        return winners.compactMapValues { $0.value }
    }

    static func logRecords(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var position = 0
        var records: [Data] = []
        var partial = Data()
        var assembling = false
        while position < bytes.count {
            let remaining = 32768 - position % 32768
            if remaining < 7 {
                position += min(remaining, bytes.count - position)
                continue
            }
            guard bytes.count - position >= 7 else { break }
            let length = Int(bytes[position + 4]) | (Int(bytes[position + 5]) << 8)
            let type = bytes[position + 6]
            if type == 0 && length == 0 {
                position += min(remaining, bytes.count - position)
                continue
            }
            guard length <= remaining - 7, length <= bytes.count - position - 7,
                (1...4).contains(type)
            else { break }
            position += 7
            let payload = bytes[position..<(position + length)]
            position += length
            switch type {
            case 1:
                partial.removeAll(keepingCapacity: true)
                assembling = false
                records.append(Data(payload))
            case 2:
                partial.removeAll(keepingCapacity: true)
                partial.append(contentsOf: payload)
                assembling = true
            case 3:
                if assembling { partial.append(contentsOf: payload) }
            case 4:
                if assembling {
                    partial.append(contentsOf: payload)
                    records.append(partial)
                }
                partial = Data()
                assembling = false
            default:
                break
            }
        }
        return records
    }

    static func batchEntries(_ record: Data) -> [LevelDBEntry] {
        var cursor = Cursor(bytes: [UInt8](record))
        guard let sequence = cursor.fixed(8), let count = cursor.fixed(4) else { return [] }
        var entries: [LevelDBEntry] = []
        for index in 0..<count {
            let (entrySequence, overflow) = sequence.addingReportingOverflow(index)
            guard !overflow, let type = cursor.fixed(1), type <= 1,
                let key = cursor.lengthPrefixed()
            else { break }
            let value: Data?
            if type == 1 {
                guard let bytes = cursor.lengthPrefixed() else { break }
                value = bytes
            } else {
                value = nil
            }
            entries.append(LevelDBEntry(key: key, value: value, sequence: entrySequence))
        }
        return entries
    }

    static func tableEntries(_ data: Data) throws -> [LevelDBEntry] {
        let bytes = [UInt8](data)
        guard bytes.count >= 48 else { throw LevelDBReaderError.badTable }
        let footerStart = bytes.count - 48
        var magic = Cursor(bytes: bytes, position: bytes.count - 8)
        guard magic.fixed(8) == 0xDB47_7524_8B80_FB57 else {
            throw LevelDBReaderError.badTable
        }
        var footer = Cursor(bytes: bytes, position: footerStart, end: bytes.count - 8)
        guard footer.handle() != nil, let indexHandle = footer.handle() else {
            throw LevelDBReaderError.badTable
        }
        let index = try blockEntries(block(indexHandle, in: bytes, limit: footerStart))
        var entries: [LevelDBEntry] = []
        for (_, value) in index {
            var handleCursor = Cursor(bytes: [UInt8](value))
            guard let handle = handleCursor.handle() else { throw LevelDBReaderError.badTable }
            let items = try blockEntries(block(handle, in: bytes, limit: footerStart))
            for (key, value) in items {
                guard key.count >= 8 else { throw LevelDBReaderError.badTable }
                var tagCursor = Cursor(bytes: [UInt8](key.suffix(8)))
                guard let tag = tagCursor.fixed(8), tag & 255 <= 1 else {
                    throw LevelDBReaderError.badTable
                }
                entries.append(
                    LevelDBEntry(
                        key: Data(key.dropLast(8)), value: tag & 255 == 1 ? value : nil,
                        sequence: tag >> 8))
            }
        }
        return entries
    }

    private static func block(
        _ handle: (offset: UInt64, size: UInt64), in bytes: [UInt8], limit: Int
    ) throws -> [UInt8] {
        guard handle.offset <= UInt64(limit), handle.size <= UInt64(limit) else {
            throw LevelDBReaderError.badTable
        }
        let offset = Int(handle.offset)
        let size = Int(handle.size)
        guard limit - offset >= 5, size <= limit - offset - 5 else {
            throw LevelDBReaderError.badTable
        }
        let payload = bytes[offset..<(offset + size)]
        switch bytes[offset + size] {
        case 0:
            return Array(payload)
        case 1:
            do {
                return [UInt8](try Snappy.decompress(Data(payload)))
            } catch {
                throw LevelDBReaderError.badTable
            }
        default:
            throw LevelDBReaderError.badTable
        }
    }

    private static func blockEntries(_ bytes: [UInt8]) throws -> [(Data, Data)] {
        guard bytes.count >= 4 else { throw LevelDBReaderError.badTable }
        var tail = Cursor(bytes: bytes, position: bytes.count - 4)
        guard let count = tail.fixed(4), count <= UInt64((bytes.count - 4) / 4) else {
            throw LevelDBReaderError.badTable
        }
        let end = bytes.count - 4 - Int(count) * 4
        var cursor = Cursor(bytes: bytes, end: end)
        var previous: [UInt8] = []
        var entries: [(Data, Data)] = []
        while cursor.position < end {
            guard let shared = cursor.varint(bits: 32),
                let nonShared = cursor.varint(bits: 32),
                let valueLength = cursor.varint(bits: 32), shared <= UInt64(previous.count),
                let delta = cursor.take(Int(nonShared)), let value = cursor.take(Int(valueLength))
            else { throw LevelDBReaderError.badTable }
            previous.removeLast(previous.count - Int(shared))
            previous.append(contentsOf: delta)
            entries.append((Data(previous), value))
        }
        return entries
    }

    private struct Cursor {
        let bytes: [UInt8]
        var position = 0
        var end: Int? = nil

        var remaining: Int { (end ?? bytes.count) - position }

        mutating func fixed(_ count: Int) -> UInt64? {
            guard count <= remaining else { return nil }
            var value: UInt64 = 0
            for index in 0..<count {
                value |= UInt64(bytes[position + index]) << (index * 8)
            }
            position += count
            return value
        }

        mutating func varint(bits: Int) -> UInt64? {
            var value: UInt64 = 0
            for shift in stride(from: 0, to: bits, by: 7) {
                guard let byte = fixed(1) else { return nil }
                let available = min(7, bits - shift)
                guard byte & 127 < UInt64(1) << available else { return nil }
                value |= (byte & 127) << shift
                if byte & 128 == 0 { return value }
            }
            return nil
        }

        mutating func take(_ count: Int) -> Data? {
            guard count <= remaining else { return nil }
            let value = Data(bytes[position..<(position + count)])
            position += count
            return value
        }

        mutating func lengthPrefixed() -> Data? {
            guard let count = varint(bits: 32) else { return nil }
            return take(Int(count))
        }

        mutating func handle() -> (offset: UInt64, size: UInt64)? {
            guard let offset = varint(bits: 64), let size = varint(bits: 64) else { return nil }
            return (offset, size)
        }
    }
}
