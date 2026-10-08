import Foundation
import Testing

@testable import ExtensionMarketplace

@Suite struct ArchiveFileReaderTests {
    private let archive = Data(
        base64Encoded:
            "UEsDBBQAAAAIAK0bSF1BbHXDIgAAACAAAAAIAAAAbWFpbi5wZGZTDXBx0zXUM+cqrswryUgtyUzWLShKLctMLedSVXX1dwMAUEsBAhQDFAAAAAgArRtIXUFsdcMiAAAAIAAAAAgAAAAAAAAAAAAAAIABAAAAAG1haW4ucGRmUEsFBgAAAAABAAEANgAAAEgAAAAAAA=="
    )!

    @Test func readsTheExpectedFileWithinItsExactLimit() throws {
        let expected = Data("%PDF-1.7\nsynthetic-preview\n%%EOF".utf8)
        #expect(
            try ArchiveFileReader.read(named: "main.pdf", from: archive, maximumBytes: 32)
                == expected)
        #expect(
            try ArchiveFileReader.read(named: "missing.pdf", from: archive, maximumBytes: 32) == nil
        )
    }

    @Test func rejectsOversizedAndMalformedArchives() {
        for limit in [-1, 0, 31] {
            #expect(throws: MarketplaceError.invalidArchive) {
                try ArchiveFileReader.read(named: "main.pdf", from: archive, maximumBytes: limit)
            }
        }
        #expect(throws: (any Error).self) {
            try ArchiveFileReader.read(named: "main.pdf", from: Data(), maximumBytes: 32)
        }
    }

    @Test func rejectsACentralDirectoryChecksumMismatch() throws {
        var damaged = archive
        let header = try #require(damaged.range(of: Data([0x50, 0x4b, 0x01, 0x02])))
        damaged[header.lowerBound + 16] ^= 0xff
        #expect(throws: MarketplaceError.invalidArchive) {
            try ArchiveFileReader.read(named: "main.pdf", from: damaged, maximumBytes: 32)
        }
    }
}
