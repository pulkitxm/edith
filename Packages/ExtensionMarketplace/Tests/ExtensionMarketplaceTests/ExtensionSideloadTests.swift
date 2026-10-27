import Foundation
import Testing

@testable import ExtensionMarketplace

@Suite struct ExtensionSideloadTests {
    private func built(_ fixture: PackageFixture, runtime: String = "local runtime") throws
        -> (ExtensionPackage, URL)
    {
        let (package, archive) = try fixture.archive("1.0.7", runtime: runtime)
        let output = fixture.directory.appendingPathComponent("dist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: archive, to: output.appendingPathComponent("keepAwake.zip"))
        try JSONEncoder().encode(package).write(
            to: output.appendingPathComponent("keepAwake.json"))
        return (package, output)
    }

    @Test func readsABuildOutputDirectoryArchiveOrRecord() throws {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        let (package, output) = try built(fixture)
        for path in [
            output, output.appendingPathComponent("keepAwake.zip"),
            output.appendingPathComponent("keepAwake.json"),
        ] {
            let sideload = try ExtensionSideload(path: path)
            #expect(sideload.package == package)
            #expect(sideload.archive.lastPathComponent == "keepAwake.zip")
        }
    }

    @Test func rejectsMissingAmbiguousAndTamperedPackages() throws {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        let (_, output) = try built(fixture)
        #expect(throws: ExtensionSideload.Failure.self) {
            try ExtensionSideload(path: output.appendingPathComponent("absent.zip"))
        }
        try FileManager.default.copyItem(
            at: output.appendingPathComponent("keepAwake.zip"),
            to: output.appendingPathComponent("other.zip"))
        try FileManager.default.copyItem(
            at: output.appendingPathComponent("keepAwake.json"),
            to: output.appendingPathComponent("other.json"))
        #expect(throws: ExtensionSideload.Failure.ambiguous(output.path)) {
            try ExtensionSideload(path: output)
        }
        let archive = output.appendingPathComponent("keepAwake.zip")
        var bytes = try Data(contentsOf: archive)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: archive)
        #expect(throws: MarketplaceError.checksumMismatch) {
            try ExtensionSideload(path: archive)
        }
    }

    @Test func aLocalSourceReplacesTheInstalledCatalogBuildOfTheSameVersion() async throws {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        let (catalog, catalogArchive) = try fixture.archive("1.0.7", runtime: "catalog runtime")
        let installer = fixture.installer(archives: [catalog.downloadURL: catalogArchive])
        _ = try await installer.install([catalog], repository: "example/app")
        let (_, output) = try built(fixture, runtime: "local runtime")
        let sideload = try ExtensionSideload(path: output)
        let admitted = AdmittedPayloads()
        _ = try await installer.install(
            [sideload.package], repository: "example/app",
            source: { _, _ in
                let copy = fixture.directory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.copyItem(at: sideload.archive, to: copy)
                return copy
            },
            admit: { directory in admitted.record(directory.lastPathComponent) })
        #expect(admitted.names == ["keepAwake"])
        #expect(try fixture.store.installedPackages() == [sideload.package])
        let runtime = fixture.store.directory(for: sideload.package)
            .appendingPathComponent("keepAwake/helper.bundle/Contents/MacOS/Runtime")
        #expect(try String(contentsOf: runtime, encoding: .utf8) == "local runtime")
    }

    @Test func aRejectingAdmissionKeepsTheCatalogBuild() async throws {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        let (catalog, catalogArchive) = try fixture.archive("1.0.7", runtime: "catalog runtime")
        let installer = fixture.installer(archives: [catalog.downloadURL: catalogArchive])
        _ = try await installer.install([catalog], repository: "example/app")
        let (_, output) = try built(fixture)
        let sideload = try ExtensionSideload(path: output)
        await #expect(throws: MarketplaceError.invalidSignature) {
            try await installer.install(
                [sideload.package], repository: "example/app",
                source: { _, _ in
                    let copy = fixture.directory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.copyItem(at: sideload.archive, to: copy)
                    return copy
                }, admit: { _ in throw MarketplaceError.invalidSignature })
        }
        #expect(try fixture.store.installedPackages() == [catalog])
    }
}

private final class AdmittedPayloads: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var names: [String] { lock.withLock { recorded } }
    func record(_ name: String) { lock.withLock { recorded.append(name) } }
}
