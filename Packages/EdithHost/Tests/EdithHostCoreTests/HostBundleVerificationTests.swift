import CryptoKit
import Darwin
import Foundation
import Testing

@testable import EdithHostCore
import ExtensionMarketplace

@Suite struct HostBundleVerificationTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func increment() { lock.withLock { value += 1 } }
        func decrement() { lock.withLock { value -= 1 } }
        func raise(to candidate: Int) { lock.withLock { value = max(value, candidate) } }
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
            try HostBundleVerification.verify(bundle) { _ in counter.increment() }
        }
        #expect(counter.count == 1)
    }

    @Test func changedExecutablesAreVerifiedAgain() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let counter = Counter()
        try HostBundleVerification.verify(bundle) { _ in counter.increment() }
        try Data("tampered binary".utf8).write(
            to: bundle.appendingPathComponent("Contents/MacOS/Runtime"))
        try HostBundleVerification.verify(bundle) { _ in counter.increment() }
        #expect(counter.count == 2)
    }

    @Test func failedVerificationIsNeverCached() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let counter = Counter()
        for _ in 0..<2 {
            #expect(throws: MarketplaceError.self) {
                try HostBundleVerification.verify(bundle) { _ in
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
        await HostBundleVerification.verifyConcurrently(bundles) { _ in counter.increment() }
        #expect(counter.count == 4)
        for bundle in bundles {
            try HostBundleVerification.verify(bundle) { _ in counter.increment() }
        }
        #expect(counter.count == 4)
    }

    @Test func blockingVerificationStaysOffTheCooperativePoolAndIsBounded() async throws {
        let bundles = try (0..<48).map { _ in try makeBundle() }
        defer {
            for bundle in bundles {
                try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent())
            }
        }
        let running = Counter()
        let peak = Counter()
        let finished = Counter()
        await HostBundleVerification.verifyConcurrently(bundles) { _ in
            running.increment()
            peak.raise(to: running.count)
            Thread.sleep(forTimeInterval: 0.01)
            running.decrement()
            finished.increment()
        }
        #expect(finished.count == 48)
        #expect(peak.count <= HostBundleVerification.maximumConcurrentVerifications)
        #expect(peak.count >= 2)
    }

    @Test func bundlesWithoutAnExecutableAreNotCached() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("Contents/MacOS"))
        let counter = Counter()
        for _ in 0..<2 {
            try HostBundleVerification.verify(bundle) { _ in counter.increment() }
        }
        #expect(counter.count == 2)
    }

    @Test func receiptsSurviveARelaunch() throws {
        let bundle = try makeBundle()
        let file = bundle.deletingLastPathComponent().appendingPathComponent("receipts.json")
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let counter = Counter()
        try HostBundleVerification.verify(
            bundle, receipts: HostBundleVerificationReceipts(file: file)
        ) { _ in counter.increment() }
        try HostBundleVerification.verify(
            bundle, receipts: HostBundleVerificationReceipts(file: file)
        ) { _ in counter.increment() }
        #expect(counter.count == 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func rewritingAFileWithItsOldTimestampIsVerifiedAgain() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let receipts = HostBundleVerificationReceipts()
        let counter = Counter()
        let executable = bundle.appendingPathComponent("Contents/MacOS/Runtime")
        let original = try #require(
            try FileManager.default.attributesOfItem(atPath: executable.path)[.modificationDate]
                as? Date)
        try HostBundleVerification.verify(bundle, receipts: receipts) { _ in counter.increment() }
        Thread.sleep(forTimeInterval: 0.01)
        try Data("BINARY".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.modificationDate: original], ofItemAtPath: executable.path)
        try HostBundleVerification.verify(bundle, receipts: receipts) { _ in counter.increment() }
        #expect(counter.count == 2)
    }

    @Test func addedResourcesAreVerifiedAgain() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let receipts = HostBundleVerificationReceipts()
        let counter = Counter()
        try HostBundleVerification.verify(bundle, receipts: receipts) { _ in counter.increment() }
        let resources = bundle.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: resources.appendingPathComponent("extra.json"))
        try HostBundleVerification.verify(bundle, receipts: receipts) { _ in counter.increment() }
        #expect(counter.count == 2)
    }

    @Test func executableDigestHashesEveryByteAcrossReadBoundaries() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let executable = bundle.appendingPathComponent("Contents/MacOS/Runtime")
        for bytes in [Data(), Data(repeating: 0xa5, count: 2_097_155)] {
            try bytes.write(to: executable)
            let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            #expect(HostBundleVerification.codeDigest(of: executable) == expected)
        }
    }

    @Test func codeDigestRejectsNonRegularFilesWithoutWaitingForAWriter() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let pipe = bundle.appendingPathComponent("Contents/MacOS/pipe")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        #expect(HostBundleVerification.codeDigest(of: pipe) == nil)
        #expect(HostBundleVerification.fingerprint(of: bundle) == nil)
        #expect(HostBundleVerification.codeDigest(of: bundle) == nil)
    }

    @Test func changedEmbeddedCodeWithRestoredModificationTimeIsVerifiedAgain() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let library = bundle.appendingPathComponent("Contents/Resources/native.dylib")
        try FileManager.default.createDirectory(
            at: library.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original".utf8).write(to: library)
        let attributes = try FileManager.default.attributesOfItem(atPath: library.path)
        let original = try #require(attributes[.modificationDate] as? Date)
        let receipts = HostBundleVerificationReceipts()
        let counter = Counter()
        try HostBundleVerification.verify(bundle, receipts: receipts) { _ in counter.increment() }
        try Data("modified".utf8).write(to: library)
        try FileManager.default.setAttributes(
            [.modificationDate: original], ofItemAtPath: library.path)
        try HostBundleVerification.verify(bundle, receipts: receipts) { _ in counter.increment() }
        #expect(counter.count == 2)
    }

    @Test func changesDuringFullVerificationNeverProduceAReceipt() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let receipts = HostBundleVerificationReceipts()
        let counter = Counter()
        try HostBundleVerification.verify(bundle, receipts: receipts) { url in
            counter.increment()
            try Data("changed while verifying".utf8).write(
                to: url.appendingPathComponent("Contents/MacOS/Runtime"))
        }
        try HostBundleVerification.verify(bundle, receipts: receipts) { _ in counter.increment() }
        #expect(counter.count == 2)
    }

    @Test func symlinkedPayloadsAlwaysRequireFullVerification() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let executable = bundle.appendingPathComponent("Contents/MacOS/Runtime")
        let outside = bundle.deletingLastPathComponent().appendingPathComponent("outside")
        try FileManager.default.moveItem(at: executable, to: outside)
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: outside)
        #expect(HostBundleVerification.codeDigest(of: executable) == nil)
        let receipts = HostBundleVerificationReceipts()
        let counter = Counter()
        for _ in 0..<2 {
            try HostBundleVerification.verify(bundle, receipts: receipts) { _ in
                counter.increment()
            }
        }
        #expect(counter.count == 2)
    }

    @Test func unwritableReceiptsFallBackToFullVerificationAfterRestart() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let blocked = bundle.deletingLastPathComponent().appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocked)
        let file = blocked.appendingPathComponent("receipts.json")
        let counter = Counter()
        for _ in 0..<2 {
            try HostBundleVerification.verify(
                bundle, receipts: HostBundleVerificationReceipts(file: file)
            ) { _ in counter.increment() }
        }
        #expect(counter.count == 2)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

}
