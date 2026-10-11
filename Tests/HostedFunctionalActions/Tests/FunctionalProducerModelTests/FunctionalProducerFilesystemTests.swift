import Darwin
import Foundation
@testable import FunctionalProducerModels
import WorkerFixtureSupport
import XCTest

final class FunctionalProducerFilesystemTests: XCTestCase {
    private let session = "12345678-1234-4123-8123-123456789abc"

    private func fixture(_ body: (URL, FunctionalPinnedPath) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directory = temporary.appendingPathComponent("producer-model-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        for relative in ["inputs/keepAwake", "outputs/keepAwake"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(relative),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try body(directory, FunctionalPinnedPath(directory, directory: true, privateMode: true))
    }

    private func resolve(_ scope: WorkerFixtureFileScope, root: URL) throws -> [WorkerFixtureResolvedFileScope] {
        let policy = try WorkerFixtureRolePolicy(owner: "keepAwake", primaryRole: .helper,
            operations: ["keepAwake.ui.read", "keepAwake.ui.update"],
            presentations: [WorkerFixturePresentationScope(location: "main", section: "keepAwake")],
            inputs: [], outputs: [], fileScopes: [scope],
            manifestSHA256: String(repeating: "a", count: 64), caseSHA256: String(repeating: "b", count: 64))
        let directory = scope.root == .ownerInputs ? "inputs" : "outputs"
        let claim = WorkerFixtureOwnedPathClaim(name: scope.name,
            path: root.path + "/" + directory + "/keepAwake/source", kind: scope.kind)
        return try policy.validateOwnedPaths([claim], owner: "keepAwake", root: root.path,
            session: session, phase: .initial)
    }

    private func file(_ purpose: WorkerFixtureFilePurpose, present: Bool) throws -> WorkerFixtureFileScope {
        try WorkerFixtureFileScope(name: "source", kind: .file, purpose: purpose,
            root: purpose == .immutableInput ? .ownerInputs : .ownerOutputs,
            components: [.literal("source")], maximumBytes: 32, maximumEntries: 1,
            initialState: present ? .present : .absent,
            allowedStates: purpose == .immutableInput ? [.present] : [.absent, .present],
            immutableFiles: [], mutableFiles: [])
    }

    func testImmutableReadRejectsInPlaceBytesAndReplacement() throws {
        try fixture { root, pin in
            let url = root.appendingPathComponent("inputs/keepAwake/source")
            try Data("original".utf8).write(to: url)
            let scopes = try FunctionalFileScopes(resolved: resolve(file(.immutableInput, present: true), root: root), root: pin)
            try scopes.requireCurrent()
            try Data("modified".utf8).write(to: url)
            XCTAssertThrowsError(try scopes.requireCurrent())
        }
        try fixture { root, pin in
            let url = root.appendingPathComponent("inputs/keepAwake/source")
            try Data("original".utf8).write(to: url)
            let scopes = try FunctionalFileScopes(resolved: resolve(file(.immutableInput, present: true), root: root), root: pin)
            try Data("original".utf8).write(to: url, options: .atomic)
            XCTAssertThrowsError(try scopes.requireCurrent())
        }
    }

    func testMutableAtomicReplacementPreservesClosedSourceAuthority() throws {
        try fixture { root, pin in
            let url = root.appendingPathComponent("outputs/keepAwake/source")
            try Data("before".utf8).write(to: url)
            let scopes = try FunctionalFileScopes(resolved: resolve(file(.mutableState, present: true), root: root), root: pin)
            try Data("after".utf8).write(to: url, options: .atomic)
            try scopes.requireCurrent()
            XCTAssertEqual(try scopes.snapshot().first?.sha256, FunctionalBytes.digest(Data("after".utf8)))
            try Data(repeating: 0, count: 33).write(to: url, options: .atomic)
            XCTAssertThrowsError(try scopes.requireCurrent())
        }
    }

    func testOutputMustStartAbsentAndRemainRegularWithinBounds() throws {
        try fixture { root, pin in
            let url = root.appendingPathComponent("outputs/keepAwake/source")
            let policy = try resolve(file(.initiallyAbsentOutput, present: false), root: root)
            let scopes = try FunctionalFileScopes(resolved: policy, root: pin)
            XCTAssertEqual(try scopes.snapshot().first?.present, false)
            try Data("encoded synthetic output".utf8).write(to: url)
            try scopes.requireCurrent()
            XCTAssertThrowsError(try FunctionalFileScopes(resolved: policy, root: pin))
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            XCTAssertThrowsError(try scopes.requireCurrent())
        }
    }

    func testClosedDirectoryInventoryRejectsExtraLeavesAndAncestorReplacement() throws {
        try fixture { root, pin in
            let url = root.appendingPathComponent("inputs/keepAwake/source")
            try FileManager.default.createDirectory(at: url.appendingPathComponent("nested"), withIntermediateDirectories: true)
            try Data("owned".utf8).write(to: url.appendingPathComponent("nested/item"))
            let scope = try WorkerFixtureFileScope(name: "source", kind: .directory, purpose: .immutableInput,
                root: .ownerInputs, components: [.literal("source")], maximumBytes: 32, maximumEntries: 2,
                initialState: .present, allowedStates: [.present],
                immutableFiles: [WorkerFixtureImmutableFileScope(components: ["nested", "item"], maximumBytes: 32)], mutableFiles: [])
            let scopes = try FunctionalFileScopes(resolved: resolve(scope, root: root), root: pin)
            try scopes.requireCurrent()
            try Data("foreign".utf8).write(to: url.appendingPathComponent("extra"))
            XCTAssertThrowsError(try scopes.requireCurrent())
            try FileManager.default.removeItem(at: url.appendingPathComponent("extra"))
            let nested = url.appendingPathComponent("nested")
            try FileManager.default.moveItem(at: nested, to: root.appendingPathComponent("retired"))
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            try Data("owned".utf8).write(to: nested.appendingPathComponent("item"))
            XCTAssertThrowsError(try scopes.requireCurrent())
        }
    }

    func testSymlinkAndHardLinkCannotBecomeImmutableInputs() throws {
        try fixture { root, pin in
            let original = root.appendingPathComponent("original")
            let url = root.appendingPathComponent("inputs/keepAwake/source")
            try Data("owned".utf8).write(to: original)
            let policy = try resolve(file(.immutableInput, present: true), root: root)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: original)
            XCTAssertThrowsError(try FunctionalFileScopes(resolved: policy, root: pin))
            try FileManager.default.removeItem(at: url)
            try FileManager.default.linkItem(at: original, to: url)
            XCTAssertThrowsError(try FunctionalFileScopes(resolved: policy, root: pin))
        }
    }

    func testNumericOneDoesNotQualifyAsBoolean() throws {
        XCTAssertTrue(try FunctionalBytes.boolean(["ok": true], "ok"))
        XCTAssertThrowsError(try FunctionalBytes.boolean(["ok": 1], "ok"))
    }
}
