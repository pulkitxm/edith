import Foundation
import ZIPFoundation

public enum ArchiveFileReader {
    public static func read(
        named name: String, from data: Data, maximumBytes: Int
    ) throws -> Data? {
        let archive = try Archive(data: data, accessMode: .read)
        guard
            let entry = archive.first(where: {
                $0.type == .file && URL(fileURLWithPath: $0.path).lastPathComponent == name
            })
        else { return nil }
        guard maximumBytes >= 0, entry.uncompressedSize <= maximumBytes else {
            throw ArchiveFileError.invalidArchive
        }
        var result = Data()
        let checksum = try archive.extract(entry) { chunk in
            guard chunk.count <= maximumBytes - result.count else {
                throw ArchiveFileError.invalidArchive
            }
            result.append(chunk)
        }
        guard checksum == entry.checksum else { throw ArchiveFileError.invalidArchive }
        return result
    }
}

public enum ArchiveFileError: Error, Equatable { case invalidArchive }
