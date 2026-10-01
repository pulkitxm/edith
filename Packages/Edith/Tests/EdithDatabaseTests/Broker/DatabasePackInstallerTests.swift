import CryptoKit
import EdithCore
import Foundation
import Testing

@testable import EdithDatabase

@Suite struct DatabasePackInstallerTests {
    @Test func checksumRejectsADifferentDigestAndLeavesTheDirectoryAlone() async throws {
        let fixture = try PackFixture()
        let payload = Data("pack-bytes".utf8)
        let installer = fixture.installer(
            checksum: String(repeating: "ab", count: 32),
            payload: payload,
            extract: { _, _ in
                throw DatabasePackInstallError.archiveInvalid
            },
            acceptSignature: true)
        await #expect(throws: DatabasePackInstallError.checksumMismatch) {
            try await installer.install()
        }
        #expect(fixture.inspect(expected: "2.0.0").state == .missing)
    }

    @Test func signatureRejectionDoesNotReplaceAnExistingPack() async throws {
        let fixture = try PackFixture()
        let payload = Data("signed-bytes".utf8)
        try DatabasePackStore.install(
            executable: fixture.executable(payload),
            version: "1.0.0",
            directories: fixture.directories)
        let installer = fixture.installer(
            checksum: DatabasePackChecksum.sha256Hex(payload),
            payload: payload,
            extract: { data, destination in try data.write(to: destination) },
            acceptSignature: false)
        await #expect(throws: DatabasePackInstallError.signatureRejected) {
            try await installer.install()
        }
        let inspection = fixture.inspect(expected: "2.0.0")
        #expect(inspection.state == .mismatched)
        #expect(inspection.installedVersion == "1.0.0")
    }

    @Test func installReplacesAMismatchedVersionAfterVerification() async throws {
        let fixture = try PackFixture()
        try DatabasePackStore.install(
            executable: fixture.executable(Data("old".utf8)),
            version: "1.0.0",
            directories: fixture.directories)
        #expect(fixture.inspect(expected: "2.0.0").state == .mismatched)
        let payload = Data("new-pack".utf8)
        let installer = fixture.installer(
            checksum: DatabasePackChecksum.sha256Hex(payload),
            payload: payload,
            extract: { data, destination in try data.write(to: destination) },
            acceptSignature: true)
        let installed = try await installer.install()
        #expect(installed.state == .current)
        #expect(installed.installedVersion == "2.0.0")
        let removed = try DatabasePackStore.remove(directories: fixture.directories)
        #expect(removed)
        #expect(fixture.inspect(expected: "2.0.0").state == .missing)
    }

    @Test func aDevelopmentBuildInvalidatesAMismatchedPackWithoutDownloading() async throws {
        let fixture = try PackFixture()
        try DatabasePackStore.install(
            executable: fixture.executable(Data("old".utf8)),
            version: "1.0.0",
            directories: fixture.directories)
        let fetched = FetchFlag()
        let installer = DatabasePackInstaller(
            directories: fixture.directories,
            expectedVersion: "2.0.0",
            requirement: "identifier \"com.pulkit.edith.database\"",
            allowsDownload: false,
            fetch: { _ in
                fetched.value = true
                return Data()
            },
            extract: { _, _ in },
            validateSignature: { _, _ in },
            progress: { _ in })
        await #expect(throws: DatabasePackInstallError.developmentBuild) {
            try await installer.install()
        }
        #expect(!fetched.value)
        #expect(fixture.inspect(expected: "2.0.0").state == .missing)
    }

    @Test func checksumFileAcceptsTheLeadingDigest() {
        let digest = String(repeating: "cd", count: 32)
        #expect(DatabasePackChecksum.digest(in: "\(digest)  edith-database.zip\n") == digest)
        #expect(DatabasePackChecksum.digest(in: "nope") == nil)
        let payload = Data("abc".utf8)
        #expect(
            DatabasePackChecksum.matches(
                payload,
                digest: SHA256.hash(data: payload).map {
                    String(format: "%02x", $0)
                }.joined()))
    }

    @Test func releaseURLsNameTheVersionedAssets() throws {
        let archive = try #require(DatabasePackRelease.archiveURL(version: "1.2.3"))
        let checksum = try #require(DatabasePackRelease.checksumURL(version: "1.2.3"))
        #expect(
            archive.absoluteString
                == "https://github.com/pulkitxm/edith/releases/download/v1.2.3/edith-database.zip")
        #expect(checksum.lastPathComponent == "edith-database.zip.sha256")
    }
}

private final class FetchFlag: @unchecked Sendable {
    var value = false
}

private struct PackFixture {
    let root: URL
    let directories: AppDirectories

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-pack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directories = AppDirectories(homeDirectory: root, directoryName: "Edith")
    }

    func executable(_ data: Data) throws -> URL {
        let url = root.appendingPathComponent("source-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }

    func inspect(expected: String) -> DatabasePackInspection {
        DatabasePackStore.inspect(expectedVersion: expected, directories: directories)
    }

    func installer(
        checksum: String,
        payload: Data,
        extract: @escaping @Sendable (Data, URL) throws -> Void,
        acceptSignature: Bool
    ) -> DatabasePackInstaller {
        DatabasePackInstaller(
            directories: directories,
            expectedVersion: "2.0.0",
            requirement: "identifier \"com.pulkit.edith.database\"",
            allowsDownload: true,
            fetch: { url in
                if url.lastPathComponent.hasSuffix(".sha256") { return Data(checksum.utf8) }
                return payload
            },
            extract: extract,
            validateSignature: { _, _ in
                if !acceptSignature { throw DatabasePackInstallError.signatureRejected }
            },
            progress: { _ in })
    }
}
