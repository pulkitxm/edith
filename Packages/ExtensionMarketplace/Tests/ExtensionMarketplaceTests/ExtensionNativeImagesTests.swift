import Darwin
import Foundation
import Testing

@testable import ExtensionMarketplace

@Suite(.serialized) struct ExtensionNativeImagesTests {
    @Test func aNewerBuildOfALoadedNativeLibraryIsReportedBeforeDyldBindsTheOldOne() throws {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        let product = "NativeFixture\(UUID().uuidString.prefix(8))"
        let library = "lib\(product).dylib"
        let installName = "@rpath/\(library)"
        let running = package("sample", "1.0.2")
        let update = package("sample", "1.0.3")
        let neighbour = package("other", "1.0.0")
        let first = "int native_fixture_one(void) { return 1; }"
        let second = first + "\nint native_fixture_two(void) { return 2; }"
        let loaded = try buildLibrary(
            first, installName: installName, in: frameworks(running, fixture))
        let replacement = try buildLibrary(
            second, installName: installName, in: frameworks(update, fixture))
        let identical = frameworks(neighbour, fixture).appendingPathComponent(library)
        try FileManager.default.createDirectory(
            at: identical.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: replacement, to: identical)
        let runtime = fixture.store.roleBundle(for: update, role: .app)
            .appendingPathComponent("Contents/MacOS/Runtime")
        try FileManager.default.createDirectory(
            at: runtime.deletingLastPathComponent(), withIntermediateDirectories: true)
        try compile(
            "int native_fixture_two(void);\nint runtime_entry(void) { return native_fixture_two(); }",
            arguments: [
                "-bundle", "-L", replacement.deletingLastPathComponent().path, "-l\(product)",
                "-Wl,-rpath,@loader_path/../Frameworks",
            ], output: runtime)

        #expect(fixture.store.loadedImageConflicts(update).isEmpty)
        #expect(
            ExtensionNativeImages.images(in: fixture.store.roleBundle(for: update, role: .app))
                .map(\.installName) == [installName])
        let handle = try #require(dlopen(loaded.path, RTLD_NOW | RTLD_LOCAL))
        defer { dlclose(handle) }
        #expect(fixture.store.loadedImageConflicts(running).isEmpty)
        #expect(fixture.store.loadedImageConflicts(update) == [installName])
        #expect(fixture.store.loadedImageConflicts(update, roles: [.helper]).isEmpty)
        #expect(fixture.store.loadedImageConflicts(neighbour).isEmpty)

        #expect(dlopen(runtime.path, RTLD_NOW | RTLD_LOCAL) == nil)
        let failure = String(cString: dlerror())
        #expect(failure.contains("Symbol not found"))
        #expect(failure.contains(loaded.resolvingSymlinksInPath().lastPathComponent))
        #expect(failure.contains("/1.0.2/"))
    }

    @Test func extensionsWithoutBundledLibrariesNeverNeedARestart() throws {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        let update = package("plain", "2.0.0")
        try FileManager.default.createDirectory(
            at: fixture.store.roleBundle(for: update, role: .app)
                .appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        #expect(fixture.store.loadedImageConflicts(update).isEmpty)
    }

    @Test func installNamesAreReadFromThinAndUniversalLibraries() throws {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        let thin = try buildLibrary(
            "int universal_fixture(void) { return 3; }", installName: "@rpath/libThin.dylib",
            in: fixture.directory)
        let universal = fixture.directory.appendingPathComponent("libUniversal.dylib")
        try compile(
            "int universal_fixture(void) { return 4; }",
            arguments: [
                "-dynamiclib", "-arch", "arm64", "-arch", "x86_64", "-install_name",
                "@rpath/libUniversal.dylib",
            ], output: universal)
        #expect(ExtensionNativeImages.image(at: thin)?.installName == "@rpath/libThin.dylib")
        #expect(
            ExtensionNativeImages.image(at: universal)?.installName == "@rpath/libUniversal.dylib")
        #expect(ExtensionNativeImages.image(at: fixture.directory) == nil)
    }

    private func package(_ id: String, _ version: String) -> ExtensionPackage {
        ExtensionPackage(
            id: id, version: version, hostABI: "synthetic-abi",
            downloadURL: URL(string: "https://synthetic.invalid/\(id).zip")!,
            sha256: String(repeating: "a", count: 64), downloadBytes: 1, installedBytes: 1)
    }

    private func frameworks(_ package: ExtensionPackage, _ fixture: PackageFixture) -> URL {
        fixture.store.roleBundle(for: package, role: .app)
            .appendingPathComponent("Contents/Frameworks")
    }

    private func buildLibrary(_ source: String, installName: String, in directory: URL) throws
        -> URL
    {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(
            String(installName.split(separator: "/").last ?? ""))
        try compile(
            source, arguments: ["-dynamiclib", "-install_name", installName], output: output)
        return output
    }

    private func compile(_ source: String, arguments: [String], output: URL) throws {
        let file = output.deletingLastPathComponent().appendingPathComponent(
            "\(UUID().uuidString).c")
        try source.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["clang"] + arguments + [file.path, "-o", output.path]
        try compiler.run()
        compiler.waitUntilExit()
        try #require(compiler.terminationStatus == 0)
    }
}
