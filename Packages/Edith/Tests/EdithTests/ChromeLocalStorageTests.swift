import Foundation
import Testing
@testable import EdithHelper

@Suite struct ChromeLocalStorageTests {
    @Test func snappyLiteralsAndOverlappingCopies() throws {
        for count in [0, 1, 60, 61, 256, 300, 65537] {
            let payload = Data(repeating: 97, count: count)
            #expect(try Snappy.decompress(literalStream(payload)) == payload)
        }
        let overlapping = Data([9, 0, 97, 30, 1, 0])
        #expect(try Snappy.decompress(overlapping) == Data(repeating: 97, count: 9))
        let shortCopy = Data([5, 0, 98, 1, 1])
        #expect(try Snappy.decompress(shortCopy) == Data("bbbbb".utf8))
        let wideCopy = Data([4, 0, 99, 11, 1, 0, 0, 0])
        #expect(try Snappy.decompress(wideCopy) == Data("cccc".utf8))
        let extendedLiteral = Data([1, 252, 0, 0, 0, 0, 120])
        #expect(try Snappy.decompress(extendedLiteral) == Data([120]))
    }

    @Test func snappyRejectsMalformedStreams() {
        let truncated: [[UInt8]] = [[], [128], [1, 0], [1, 240], [4, 2, 1], [4, 3, 1, 0]]
        for bytes in truncated {
            #expect(throws: SnappyError.truncated) {
                try Snappy.decompress(Data(bytes))
            }
        }
        let badOffsets: [[UInt8]] = [[4, 1, 0], [4, 1, 1], [5, 0, 97, 1, 2]]
        for bytes in badOffsets {
            #expect(throws: SnappyError.invalidOffset) {
                try Snappy.decompress(Data(bytes))
            }
        }
        let mismatched: [[UInt8]] = [[2, 0, 97], [0, 0, 97], [255, 255, 255, 255, 31]]
        for bytes in mismatched {
            #expect(throws: SnappyError.lengthMismatch) {
                try Snappy.decompress(Data(bytes))
            }
        }
    }

    @Test func logReassemblesFragmentsAndSkipsBlockPadding() {
        let full = Data("full".utf8)
        let large = Data(repeating: 120, count: 40000)
        var log = physical(full, type: 1)
        let firstLength = 32768 - log.count - 7
        log.append(physical(Data(large.prefix(firstLength)), type: 2))
        log.append(physical(Data(large.dropFirst(firstLength)), type: 4))
        log.append(contentsOf: [0, 0, 0])
        #expect(LevelDBReader.logRecords(log) == [full, large])

        let filler = Data(repeating: 65, count: 32758)
        var padded = physical(filler, type: 1)
        padded.append(contentsOf: [0, 0, 0])
        padded.append(physical(full, type: 1))
        #expect(LevelDBReader.logRecords(padded) == [filler, full])

        var zeroPadded = physical(full, type: 1)
        zeroPadded.append(Data(repeating: 0, count: 32768 - zeroPadded.count))
        zeroPadded.append(physical(full, type: 1))
        #expect(LevelDBReader.logRecords(zeroPadded) == [full, full])
    }

    @Test func logDropsBrokenFragmentsAndMalformedTails() {
        let part = Data([1, 2])
        let whole = Data([3, 4])
        var broken = physical(part, type: 2)
        broken.append(physical(whole, type: 1))
        broken.append(physical(part, type: 4))
        broken.append(physical(part, type: 3))
        #expect(LevelDBReader.logRecords(broken) == [whole])

        var fragmented = physical(part, type: 2)
        fragmented.append(physical(whole, type: 3))
        fragmented.append(physical(part, type: 4))
        #expect(LevelDBReader.logRecords(fragmented) == [part + whole + part])

        var restarted = physical(part, type: 2)
        restarted.append(physical(whole, type: 2))
        restarted.append(physical(part, type: 4))
        #expect(LevelDBReader.logRecords(restarted) == [whole + part])

        for tail in [
            Data(physical(part, type: 1).dropLast()),
            Data([0, 0, 0, 0, 255, 255, 1]),
            physical(part, type: 9),
            physical(part, type: 2),
        ] {
            #expect(LevelDBReader.logRecords(physical(whole, type: 1) + tail) == [whole])
        }
    }

    @Test func batchesAssignSequencesAndStopAtMalformedOperations() {
        let key = Data("key".utf8)
        let value = Data("value".utf8)
        let entries = [
            LevelDBEntry(key: key, value: value, sequence: 42),
            LevelDBEntry(key: key, value: nil, sequence: 43),
            LevelDBEntry(key: Data(), value: Data(), sequence: 44),
        ]
        let record = batch(sequence: 42, operations: [(key, value), (key, nil), (Data(), Data())])
        #expect(LevelDBReader.batchEntries(record) == entries)
        #expect(LevelDBReader.batchEntries(Data(record.dropLast())) == Array(entries.prefix(2)))
        #expect(LevelDBReader.batchEntries(Data([1, 2, 3])).isEmpty)
        let invalid = little(42, count: 8) + little(1, count: 4) + Data([2])
        #expect(LevelDBReader.batchEntries(invalid).isEmpty)
        let badLength = little(42, count: 8) + little(1, count: 4)
            + Data([1, 255, 255, 255, 255, 31])
        #expect(LevelDBReader.batchEntries(badLength).isEmpty)
        let overflow = batch(sequence: .max, operations: [(key, value), (key, nil)])
        #expect(LevelDBReader.batchEntries(overflow).count == 1)
    }

    @Test func tablesDecodeSharedPrefixesAndCompression() throws {
        let entries = [
            LevelDBEntry(key: Data("prefix-a".utf8), value: Data([1, 2]), sequence: 12),
            LevelDBEntry(key: Data("prefix-b".utf8), value: Data([3, 4]), sequence: 11),
            LevelDBEntry(key: Data("prefix-c".utf8), value: nil, sequence: 10),
        ]
        for compressed in [false, true] {
            let parsed = try LevelDBReader.tableEntries(table(entries, compressed: compressed))
            #expect(parsed == entries)
        }
        #expect(try LevelDBReader.tableEntries(table([])).isEmpty)
    }

    @Test func malformedTablesThrowBadTable() {
        let entries = [LevelDBEntry(key: Data([97]), value: Data([98]), sequence: 1)]
        let valid = table(entries)
        var wrongMagic = valid
        wrongMagic[wrongMagic.count - 1] = 0
        var wrongCompression = valid
        let dataBlock = block([(internalKey(entries[0]), Data([98]))])
        wrongCompression[dataBlock.count] = 2
        var badRestartCount = valid
        badRestartCount.replaceSubrange(
            (dataBlock.count - 4)..<dataBlock.count, with: [255, 255, 255, 255])
        var badShared = valid
        badShared[0] = 1
        var badHandle = valid
        let footer = badHandle.count - 48
        badHandle.replaceSubrange(footer..<(footer + 40), with: repeatElement(255, count: 40))
        let malformed = [
            Data(), Data(valid.dropLast()), wrongMagic, wrongCompression,
            badRestartCount, badShared, badHandle,
        ]
        for data in malformed {
            #expect(throws: LevelDBReaderError.badTable) {
                try LevelDBReader.tableEntries(data)
            }
        }
    }

    @Test func stringsAndStorageKeysDecode() throws {
        #expect(ChromeLocalStorage.decodeString(Data([1, 99, 97, 102, 233])) == "café")
        #expect(ChromeLocalStorage.decodeString(Data([1, 0, 128, 255])) == "\u{0}\u{80}ÿ")
        #expect(ChromeLocalStorage.decodeString(utf16("雪😀")) == "雪😀")
        #expect(ChromeLocalStorage.decodeString(Data([0])) == "")
        #expect(ChromeLocalStorage.decodeString(Data([1])) == "")
        for invalid in [Data(), Data([2, 97]), Data([0, 97])] {
            #expect(ChromeLocalStorage.decodeString(invalid) == nil)
        }
        let latin = try #require(
            ChromeLocalStorage.storageKey(storage("https://example.com", Data([1, 233]))))
        #expect(latin.origin == "https://example.com")
        #expect(latin.name == "é")
        let unicode = try #require(
            ChromeLocalStorage.storageKey(storage("http://localhost:3000", utf16("名前"))))
        #expect(unicode.origin == "http://localhost:3000")
        #expect(unicode.name == "名前")
        let empty = try #require(
            ChromeLocalStorage.storageKey(storage("https://example.com", Data([1]))))
        #expect(empty.name.isEmpty)
        for invalid in [
            Data("VERSION".utf8), Data("META:https://example.com".utf8),
            Data("METAACCESS:https://example.com".utf8),
            storage("https://a.com/^0https://b.com", latin1("key")),
            storage("file:///tmp", latin1("key")), Data("_https://example.com".utf8),
            storage("https://example.com", Data()), storage("", latin1("key")),
            Data([95, 255, 0, 1, 97]),
        ] {
            #expect(ChromeLocalStorage.storageKey(invalid) == nil)
        }
    }

    @Test func liveEntriesAndReadMergeTablesAndLogs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let origin = "https://example.com"
        let theme = storage(origin, latin1("theme"))
        let removed = storage(origin, latin1("removed"))
        let name = storage(origin, utf16("名前"))
        let local = storage("http://localhost:3000", latin1("mode"))
        let stable = storage(origin, latin1("stable"))
        let tableEntries = [
            LevelDBEntry(key: theme, value: latin1("old"), sequence: 3),
            LevelDBEntry(key: removed, value: latin1("old"), sequence: 4),
            LevelDBEntry(key: stable, value: latin1("table"), sequence: 100),
        ]
        try table(tableEntries).write(to: directory.appendingPathComponent("000001.ldb"))
        try table([LevelDBEntry(key: local, value: latin1("dev"), sequence: 5)], compressed: true)
            .write(to: directory.appendingPathComponent("000002.sst"))
        let operations: [(Data, Data?)] = [
            (theme, latin1("dark")), (removed, nil), (name, utf16("雪😀")),
            (stable, latin1("older log")),
            (Data("VERSION".utf8), latin1("1")),
            (Data("META:https://example.com".utf8), latin1("metadata")),
            (Data("METAACCESS:https://example.com".utf8), latin1("metadata")),
            (storage("https://a.com/^0https://b.com", latin1("key")), latin1("skip")),
            (storage(origin, latin1("bad")), Data([2, 1])),
        ]
        var log = physical(batch(sequence: 20, operations: operations), type: 1)
        log.append(contentsOf: [0, 0, 0, 0, 10, 0, 1, 1])
        try log.write(to: directory.appendingPathComponent("000003.log"))
        try Data([1, 2, 3]).write(to: directory.appendingPathComponent("000004.ldb"))
        try physical(batch(sequence: 200, operations: [(theme, nil)]), type: 1)
            .write(to: directory.appendingPathComponent("ignored.txt"))
        let live = try LevelDBReader.liveEntries(inDirectory: directory)
        #expect(live[theme] == latin1("dark"))
        #expect(live[removed] == nil)
        #expect(live[stable] == latin1("table"))
        #expect(try ChromeLocalStorage.read(directory: directory) == [
            origin: ["theme": "dark", "名前": "雪😀", "stable": "table"],
            "http://localhost:3000": ["mode": "dev"],
        ])
    }

    @Test func missingDirectoryThrows() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        #expect(throws: LevelDBReaderError.missingDirectory) {
            try ChromeLocalStorage.read(directory: directory)
        }
    }

    private func little(_ value: UInt64, count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    private func varint(_ value: UInt64) -> Data {
        var remaining = value
        var bytes = Data()
        repeat {
            let byte = UInt8(remaining & 127)
            remaining >>= 7
            bytes.append(byte | (remaining == 0 ? 0 : 128))
        } while remaining != 0
        return bytes
    }

    private func literalStream(_ payload: Data) -> Data {
        var result = varint(UInt64(payload.count))
        guard !payload.isEmpty else { return result }
        let length = UInt64(payload.count - 1)
        if length < 60 {
            result.append(UInt8(length << 2))
        } else {
            var width = 1
            while length >> (width * 8) != 0 { width += 1 }
            result.append(UInt8((59 + width) << 2))
            result.append(little(length, count: width))
        }
        result.append(payload)
        return result
    }

    private func physical(_ payload: Data, type: UInt8) -> Data {
        little(0, count: 4) + little(UInt64(payload.count), count: 2) + Data([type]) + payload
    }

    private func batch(sequence: UInt64, operations: [(Data, Data?)]) -> Data {
        var result = little(sequence, count: 8) + little(UInt64(operations.count), count: 4)
        for (key, value) in operations {
            result.append(value == nil ? 0 : 1)
            result.append(varint(UInt64(key.count)))
            result.append(key)
            if let value {
                result.append(varint(UInt64(value.count)))
                result.append(value)
            }
        }
        return result
    }

    private func internalKey(_ entry: LevelDBEntry) -> Data {
        entry.key + little((entry.sequence << 8) | (entry.value == nil ? 0 : 1), count: 8)
    }

    private func block(_ entries: [(Data, Data)]) -> Data {
        var result = Data()
        var previous: [UInt8] = []
        for (key, value) in entries {
            let bytes = [UInt8](key)
            var shared = 0
            while shared < min(previous.count, bytes.count), previous[shared] == bytes[shared] {
                shared += 1
            }
            result.append(varint(UInt64(shared)))
            result.append(varint(UInt64(bytes.count - shared)))
            result.append(varint(UInt64(value.count)))
            result.append(contentsOf: bytes.dropFirst(shared))
            result.append(value)
            previous = bytes
        }
        result.append(little(0, count: 4))
        result.append(little(1, count: 4))
        return result
    }

    private func table(_ entries: [LevelDBEntry], compressed: Bool = false) -> Data {
        let contents = block(entries.map { (internalKey($0), $0.value ?? Data()) })
        let dataBlock = compressed ? literalStream(contents) : contents
        var result = dataBlock + Data([compressed ? 1 : 0]) + little(0, count: 4)
        let metaindex = block([])
        let metaHandle = varint(UInt64(result.count)) + varint(UInt64(metaindex.count))
        result.append(metaindex + Data(repeating: 0, count: 5))
        let dataHandle = varint(0) + varint(UInt64(dataBlock.count))
        let index = block([(entries.last.map { internalKey($0) } ?? Data(), dataHandle)])
        let indexHandle = varint(UInt64(result.count)) + varint(UInt64(index.count))
        result.append(index + Data(repeating: 0, count: 5))
        var footer = metaHandle + indexHandle
        footer.append(Data(repeating: 0, count: 40 - footer.count))
        footer.append(little(0xDB47_7524_8B80_FB57, count: 8))
        result.append(footer)
        return result
    }

    private func latin1(_ text: String) -> Data {
        Data([1]) + Data(text.utf8)
    }

    private func utf16(_ text: String) -> Data {
        var result = Data([0])
        for unit in text.utf16 { result.append(little(UInt64(unit), count: 2)) }
        return result
    }

    private func storage(_ origin: String, _ name: Data) -> Data {
        Data([95]) + Data(origin.utf8) + Data([0]) + name
    }
}
