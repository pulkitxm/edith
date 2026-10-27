import Foundation
import Testing

@testable import ExtensionMarketplace

@Suite struct ExtensionBundleVerificationTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func increment() { lock.withLock { value += 1 } }
    }

    private func makeBundle() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundle-verification-\(UUID().uuidString)")
        let contents = root.appendingPathComponent("app.bundle/Contents")
        for directory in ["MacOS", "_CodeSignature"] {
            try FileManager.default.createDirectory(
                at: contents.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try Data("plist".utf8).write(to: contents.appendingPathComponent("Info.plist"))
        try Data("seal".utf8).write(
            to: contents.appendingPathComponent("_CodeSignature/CodeResources"))
        try Data("binary".utf8).write(to: contents.appendingPathComponent("MacOS/Runtime"))
        return root.appendingPathComponent("app.bundle")
    }

    @Test func unchangedBundlesAreVerifiedOncePerProcess() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let counter = Counter()
        for _ in 0..<5 {
            try ExtensionBundleVerification.verify(bundle) { _ in counter.increment() }
        }
        #expect(counter.count == 1)
    }

    @Test func changedExecutablesAreVerifiedAgain() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let counter = Counter()
        try ExtensionBundleVerification.verify(bundle) { _ in counter.increment() }
        try Data("tampered binary".utf8).write(
            to: bundle.appendingPathComponent("Contents/MacOS/Runtime"))
        try ExtensionBundleVerification.verify(bundle) { _ in counter.increment() }
        #expect(counter.count == 2)
    }

    @Test func failedVerificationIsNeverCached() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let counter = Counter()
        for _ in 0..<2 {
            #expect(throws: MarketplaceError.self) {
                try ExtensionBundleVerification.verify(bundle) { _ in
                    counter.increment()
                    throw MarketplaceError.invalidSignature
                }
            }
        }
        #expect(counter.count == 2)
    }

    @Test func concurrentPreVerificationLetsTheLoadSkipTheCheck() async throws {
        let bundles = try (0..<4).map { _ in try makeBundle() }
        defer {
            for bundle in bundles {
                try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent())
            }
        }
        let counter = Counter()
        await ExtensionBundleVerification.verifyConcurrently(bundles) { _ in counter.increment() }
        #expect(counter.count == 4)
        for bundle in bundles {
            try ExtensionBundleVerification.verify(bundle) { _ in counter.increment() }
        }
        #expect(counter.count == 4)
    }

    @Test func bundlesWithoutAnExecutableAreNotCached() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("Contents/MacOS"))
        let counter = Counter()
        for _ in 0..<2 {
            try ExtensionBundleVerification.verify(bundle) { _ in counter.increment() }
        }
        #expect(counter.count == 2)
    }
}
