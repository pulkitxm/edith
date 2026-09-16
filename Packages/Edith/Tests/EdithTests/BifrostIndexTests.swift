import Foundation
import Testing

@testable import EdithKit

@Suite struct BifrostIndexTests {
    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bifrost-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeBundle(_ name: String, in root: URL) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("\(name).app"), withIntermediateDirectories: true)
    }

    @Test func scanningFindsBundlesAndNamesThemFromTheFileName() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeBundle("Safari", in: root)
        try makeBundle("Google Chrome", in: root)

        let found = BifrostApplicationScanner.scan(roots: [root], readName: { _ in nil })

        #expect(found.map(\.name) == ["Google Chrome", "Safari"])
        #expect(found.allSatisfy { $0.path.hasSuffix(".app") })
    }

    @Test func scanningDescendsIntoSubfoldersButNotIntoBundles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let utilities = root.appendingPathComponent("Utilities", isDirectory: true)
        try FileManager.default.createDirectory(at: utilities, withIntermediateDirectories: true)
        try makeBundle("Terminal", in: utilities)
        try makeBundle("Outer", in: root)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Outer.app/Contents/Nested.app"),
            withIntermediateDirectories: true)

        let found = BifrostApplicationScanner.scan(roots: [root], readName: { _ in nil })

        #expect(found.map(\.name) == ["Outer", "Terminal"])
    }

    @Test func aBundleIsIndexedOnceEvenAcrossOverlappingRoots() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeBundle("Notes", in: root)

        let found = BifrostApplicationScanner.scan(roots: [root, root], readName: { _ in nil })

        #expect(found.count == 1)
    }

    @Test func aMissingRootIsSkippedRatherThanFatal() {
        let missing = URL(fileURLWithPath: "/nowhere-\(UUID().uuidString)", isDirectory: true)
        #expect(BifrostApplicationScanner.scan(roots: [missing], readName: { _ in nil }).isEmpty)
    }

    @Test func theDisplayNameWinsOverTheFileName() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeBundle("com.example.thing", in: root)

        let found = BifrostApplicationScanner.scan(roots: [root], readName: { _ in "Thing" })

        #expect(found.map(\.name) == ["Thing"])
    }

    @Test func theIndexRoundTripsThroughItsCacheFile() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BifrostIndexStore(location: root.appendingPathComponent("index.json"))
        let index = BifrostIndex(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            applications: [BifrostApplication(name: "Safari", path: "/Applications/Safari.app")])

        store.save(index)
        let loaded = store.load()

        #expect(loaded == index)
        #expect(loaded?.applications.first?.searchTarget == BifrostMatchTarget("Safari"))
    }

    @Test func anEmptyOrUnreadableCacheIsTreatedAsNoCache() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let location = root.appendingPathComponent("index.json")
        let store = BifrostIndexStore(location: location)

        #expect(store.load() == nil)
        store.save(BifrostIndex(generatedAt: Date(), applications: []))
        #expect(store.load() == nil)
        try Data("not json".utf8).write(to: location)
        #expect(store.load() == nil)
    }

    @Test func removingTheCacheLeavesNothingBehind() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BifrostIndexStore(location: root.appendingPathComponent("index.json"))
        store.save(
            BifrostIndex(
                generatedAt: Date(),
                applications: [BifrostApplication(name: "Safari", path: "/a/Safari.app")]))

        store.remove()

        #expect(store.load() == nil)
    }
}
