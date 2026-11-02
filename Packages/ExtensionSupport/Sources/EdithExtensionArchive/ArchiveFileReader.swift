import Foundation

public enum ArchiveFileReader {
    static let unzip = URL(fileURLWithPath: "/usr/bin/unzip")

    public static func read(
        named name: String, from data: Data, maximumBytes: Int
    ) throws -> Data? {
        guard maximumBytes >= 0 else { throw ArchiveFileError.invalidArchive }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("archive.zip")
        try data.write(to: archive)
        let listing = try run(["-Z1", archive.path], limit: 1_048_576)
        guard
            let entry = String(decoding: listing, as: UTF8.self).split(separator: "\n")
                .map(String.init)
                .first(where: {
                    !$0.hasSuffix("/") && URL(fileURLWithPath: $0).lastPathComponent == name
                })
        else { return nil }
        let pattern = escaped(entry)
        let details = String(
            decoding: try run(["-Zv", archive.path, pattern], limit: 1_048_576), as: UTF8.self)
        guard
            let line = details.split(separator: "\n").first(where: {
                $0.contains("32-bit CRC value (hex):")
            }),
            let expected = line.split(separator: " ").last.flatMap({ UInt32($0, radix: 16) })
        else { throw ArchiveFileError.invalidArchive }
        let contents = try run(["-qq", "-p", archive.path, pattern], limit: maximumBytes)
        guard crc32(contents) == expected else { throw ArchiveFileError.invalidArchive }
        return contents
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
        }
        return ~crc
    }

    static func escaped(_ pattern: String) -> String {
        pattern.reduce(into: "") { result, character in
            if "[]*?\\".contains(character) { result.append("\\") }
            result.append(character)
        }
    }

    private static func run(_ arguments: [String], limit: Int) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = unzip
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        var result = Data()
        var exceeded = false
        let reader = output.fileHandleForReading
        while let chunk = try reader.read(upToCount: 65_536), !chunk.isEmpty {
            guard chunk.count <= limit - result.count else {
                exceeded = true
                process.terminate()
                break
            }
            result.append(chunk)
        }
        process.waitUntilExit()
        guard !exceeded, process.terminationReason == .exit, process.terminationStatus == 0
        else { throw ArchiveFileError.invalidArchive }
        return result
    }
}

public enum ArchiveFileError: Error, Equatable { case invalidArchive }
