import Darwin
import Foundation
import Testing

@testable import EdithHostCore

struct HostStorageAccountingTests {
    @Test func nestedCategoriesAreExclusiveAndHardLinksCountOnce() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let app = try fixture.directory("App")
        let packages = try fixture.directory("App/Packages")
        let data = try fixture.directory("Data")
        let first = try fixture.file("App/executable", count: 7000)
        _ = try fixture.file("App/Packages/payload", count: 5000)
        try FileManager.default.linkItem(at: first, to: data.appendingPathComponent("linked"))
        let result = try HostStorageAccounting.scan(scopes: [
            .init(id: "app", root: app), .init(id: "packages", root: packages),
            .init(id: "data", root: data),
        ])
        #expect(result.bytes["app"]?.logical == 7000)
        #expect(result.bytes["packages"]?.logical == 5000)
        #expect(result.bytes["data"]?.logical == 0)
        #expect(result.total.logical == 12000)
        let allocated = try fixture.allocated([
            "App", "App/Packages", "Data", "App/executable", "App/Packages/payload",
        ])
        #expect(result.total.allocated == allocated)
        #expect(result.total.complete)
    }

    @Test func sparseFilesSeparateLogicalLengthFromAllocatedBlocks() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let root = try fixture.directory("Sparse")
        let path = root.appendingPathComponent("content")
        let descriptor = open(path.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        #expect(ftruncate(descriptor, 64 * 1024 * 1024) == 0)
        let result = try HostStorageAccounting.scan(scopes: [.init(id: "sparse", root: root)])
        #expect(result.total.logical == 64 * 1024 * 1024)
        #expect(result.total.allocated < result.total.logical)
        let allocated = try fixture.allocated(["Sparse", "Sparse/content"])
        #expect(result.total.allocated == allocated)
    }

    @Test func exactFileRootsAreMeasuredWithoutEnumeratingSiblingRecords() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try fixture.directory("Preferences")
        let owned = try fixture.file("Preferences/owned.plist", count: 200)
        _ = try fixture.file("Preferences/other.plist", count: 9000)
        let result = try HostStorageAccounting.scan(scopes: [.init(id: "owned", root: owned)])
        #expect(result.total.logical == 200)
        #expect(result.total.complete)
        let allocated = try fixture.allocated(["Preferences/owned.plist"])
        #expect(result.total.allocated == allocated)
    }

    @Test func symlinkRootsAncestorsAndDescendantsCannotEscapeTheSealedRoots() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let inside = try fixture.directory("Inside")
        let outside = try fixture.directory("Outside")
        _ = try fixture.file("Outside/private-record", count: 8000)
        _ = try fixture.file("Inside/local", count: 13)
        let link = inside.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let result = try HostStorageAccounting.scan(scopes: [.init(id: "inside", root: inside)])
        #expect(result.total.logical == 13)
        #expect(!result.issues.isEmpty)
        #expect(!result.issues.joined().contains("private-record"))
        for root in [link, link.appendingPathComponent("nested")] {
            let refused = try HostStorageAccounting.scan(scopes: [
                .init(id: "refused", root: root, expected: true)
            ])
            #expect(refused.total.logical == 0)
            #expect(!refused.total.complete)
        }
    }

    @Test func limitsAndMissingExpectedDirectoriesAreExplicitlyPartial() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let root = try fixture.directory("Limited")
        for index in 0..<5 { _ = try fixture.file("Limited/item\(index)", count: 1) }
        let limited = try HostStorageAccounting.scan(
            scopes: [.init(id: "limited", root: root)], maximumEntries: 2)
        #expect(!limited.total.complete)
        #expect(!limited.issues.isEmpty)
        let missing = root.appendingPathComponent("missing")
        let absent = try HostStorageAccounting.scan(scopes: [.init(id: "absent", root: missing)])
        #expect(absent.total.logical == 0)
        #expect(absent.total.complete)
        #expect(!absent.total.exists)
        let expected = try HostStorageAccounting.scan(scopes: [
            .init(id: "expected", root: missing, expected: true)
        ])
        #expect(!expected.total.complete)
    }

    @Test func cancellationInterruptsTraversalAndCannotReturnAPartialSuccess() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let root = try fixture.directory("Cancelled")
        for index in 0..<10 { _ = try fixture.file("Cancelled/item\(index)", count: 1) }
        let cancellation = CancellationProbe()
        #expect(throws: CancellationError.self) {
            try HostStorageAccounting.scan(
                scopes: [.init(id: "cancelled", root: root)], isCancelled: { cancellation.check() })
        }
        #expect(cancellation.count > 3)
    }

    @Test func duplicateIDsAndTraversalRootsAreRejected() throws {
        #expect(throws: CocoaError.self) {
            try HostStorageAccounting.scan(scopes: [
                .init(id: "same", root: URL(fileURLWithPath: "/a")),
                .init(id: "same", root: URL(fileURLWithPath: "/b")),
            ])
        }
        #expect(throws: CocoaError.self) {
            try HostStorageAccounting.scan(scopes: [
                .init(id: "traversal", root: URL(fileURLWithPath: "/a/../b"))
            ])
        }
    }

    private final class CancellationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var checks = 0
        var count: Int { lock.withLock { checks } }
        func check() -> Bool {
            lock.withLock {
                checks += 1; return checks > 3
            }
        }
    }

    private struct Fixture {
        let root: URL
        init() throws {
            root = URL(fileURLWithPath: "/private/tmp")
                .appendingPathComponent("storage-accounting-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func directory(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func file(_ name: String, count: Int) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data(repeating: 65, count: count).write(to: url)
            return url
        }
        func allocated(_ paths: [String]) throws -> Int64 {
            try paths.reduce(Int64(0)) { sum, path in
                var information = stat()
                guard lstat(root.appendingPathComponent(path).path, &information) == 0 else {
                    throw CocoaError(.fileReadUnknown)
                }
                return sum + Int64(information.st_blocks) * 512
            }
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }
}
