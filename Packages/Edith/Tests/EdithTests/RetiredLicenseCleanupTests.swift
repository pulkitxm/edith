import EdithKit
import Foundation
import Testing

@Suite struct RetiredLicenseCleanupTests {
    private func makeDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("retired-license-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "retired-license-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return defaults
    }

    @Test func removesEveryRetiredCredentialFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for file in RetiredLicenseCleanup.files {
            try Data("secret".utf8).write(to: directory.appendingPathComponent(file))
        }

        RetiredLicenseCleanup.run(directory: directory, defaults: try makeDefaults())

        for file in RetiredLicenseCleanup.files {
            #expect(
                !FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(file).path))
        }
    }

    @Test func clearsRetiredDefaultsKeys() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try makeDefaults()
        defaults.set(true, forKey: "licenseActivated")
        defaults.set("Power", forKey: "licenseLabel")
        defaults.set("Pulkit", forKey: "licenseName")

        RetiredLicenseCleanup.run(directory: directory, defaults: defaults)

        for key in RetiredLicenseCleanup.defaultsKeys {
            #expect(defaults.object(forKey: key) == nil)
        }
    }

    @Test func leavesUnrelatedFilesAndKeysAlone() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keep = directory.appendingPathComponent("usage-history.json")
        try Data("[]".utf8).write(to: keep)
        let defaults = try makeDefaults()
        defaults.set("accent", forKey: "theme")

        RetiredLicenseCleanup.run(directory: directory, defaults: defaults)

        #expect(FileManager.default.fileExists(atPath: keep.path))
        #expect(defaults.string(forKey: "theme") == "accent")
    }

    @Test func succeedsWhenNothingIsLeftBehind() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        RetiredLicenseCleanup.run(directory: directory, defaults: try makeDefaults())

        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
