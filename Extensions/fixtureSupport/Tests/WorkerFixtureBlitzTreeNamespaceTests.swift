import Darwin
import Foundation
import Testing
@testable import WorkerFixtureSupport

@MainActor struct WorkerFixtureBlitzTreeNamespaceTests {
    @MainActor private final class Gate {
        var entered = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        func hold() async {
            entered = true
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            continuation?.resume(); continuation = nil
        }
    }

    @MainActor private final class Fixture {
        let root: URL
        let source: URL
        let destination: URL
        let sourceScope: WorkerFixtureResolvedFileScope
        let destinationScope: WorkerFixtureResolvedFileScope
        let engine = WorkerFixtureUIProcess(
            pid: 41, birthSeconds: 10, birthMicroseconds: 20, uid: getuid(),
            executable: "/private/synthetic/Fixture.app/Contents/MacOS/Edith",
            executableSHA256: String(repeating: "a", count: 64))
        var current = true

        init(count: Int = 1) throws {
            guard let physical = realpath(FileManager.default.temporaryDirectory.path, nil) else {
                throw WorkerFixtureError.invalid
            }
            defer { free(physical) }
            let session = UUID().uuidString.lowercased()
            root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
                .appendingPathComponent("functional-fixture-" + session)
            source = root.appendingPathComponent("outputs/blitztree/initial/scan")
            destination = root.appendingPathComponent("outputs/blitztree/initial/trash")
            for url in [source, destination] {
                try FileManager.default.createDirectory(
                    at: url, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            let scopes = try [false, true].map { target in
                try WorkerFixtureFileScope(
                    name: target ? "trash-directory" : "scan-directory", kind: .directory,
                    purpose: .mutableState, root: .ownerOutputs,
                    components: [.phase, .literal(target ? "trash" : "scan")],
                    maximumBytes: 4096 * count,
                    maximumEntries: count, initialState: .present, allowedStates: [.present],
                    immutableFiles: [],
                    mutableFiles: try (0..<count).map { index in
                        try WorkerFixtureMutableFileScope(
                            components: [index == 0 ? "victim.bin" : "extra.bin"],
                            maximumBytes: 4096, initialState: target ? .absent : .present,
                            allowedStates: [.present, .absent])
                    })
            }
            let policy = try WorkerFixtureRolePolicy(
                owner: "blitztree", primaryRole: .app, operations: ["blitztree.ui.trash"],
                presentations: [], inputs: [], outputs: [], fileScopes: scopes,
                manifestSHA256: String(repeating: "a", count: 64),
                caseSHA256: String(repeating: "b", count: 64))
            let resolved = try policy.resolvedOwnedPaths(
                root: root.path, session: session, phase: .initial)
            sourceScope = resolved[0]; destinationScope = resolved[1]
            let victim = source.appendingPathComponent("victim.bin")
            try Data(repeating: 42, count: 4096).write(to: victim)
            guard chmod(victim.path, 0o600) == 0 else { throw WorkerFixtureError.invalid }
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func claim(owner: String = "blitztree") throws -> WorkerFixtureBlitzTreeNamespace {
            try WorkerFixtureBlitzTreeNamespace(
                owner: owner, source: sourceScope, destination: destinationScope)
        }

        func lease() throws -> WorkerFixtureCooperativeNamespaceLease {
            try WorkerFixtureCooperativeNamespaceLease(
                blitzTree: claim(), engine: engine,
                requireAdmission: { [self] in
                    guard current else { throw WorkerFixtureError.invalid }
                })
        }
    }

    @Test func oneFileAdmissionRejectsOtherOwnersAndDifferentFileCounts() throws {
        let fixture = try Fixture()
        #expect(throws: (any Error).self) { try fixture.claim(owner: "cleaner") }
        let two = try Fixture(count: 2)
        #expect(throws: (any Error).self) { try two.claim() }
        #expect(throws: (any Error).self) {
            try WorkerFixtureCooperativeNamespaceLease(
                source: fixture.sourceScope, destination: fixture.destinationScope,
                engine: fixture.engine, requireAdmission: {})
        }
    }

    @Test func capturedVictimMovesWithoutCopyAndCannotMoveTwice() async throws {
        let fixture = try Fixture()
        let lease = try fixture.lease()
        let input = fixture.source.appendingPathComponent("victim.bin")
        var before = stat()
        #expect(lstat(input.path, &before) == 0)
        let output = try await lease.withAction { action in
            let output = try lease.moveToPrivateTrash(input, action: action)
            #expect(throws: (any Error).self) {
                try lease.moveToPrivateTrash(input, action: action)
            }
            return output
        }
        var after = stat()
        #expect(lstat(output.path, &after) == 0)
        #expect(before.st_dev == after.st_dev && before.st_ino == after.st_ino)
        #expect(try Data(contentsOf: output) == Data(repeating: 42, count: 4096))
        await lease.closeAndWait()
    }

    @Test func inodeSubstitutionRevocationAndExtraLeavesRejectBeforeMoving() async throws {
        for change in 0..<3 {
            let fixture = try Fixture()
            let lease = try fixture.lease()
            let input = fixture.source.appendingPathComponent("victim.bin")
            await #expect(throws: (any Error).self) {
                try await lease.withAction { action in
                    switch change {
                    case 0:
                        try FileManager.default.moveItem(
                            at: input, to: fixture.root.appendingPathComponent("held.bin"))
                        try Data(repeating: 42, count: 4096).write(to: input)
                        #expect(chmod(input.path, 0o600) == 0)
                    case 1: fixture.current = false
                    default:
                        try Data([1]).write(to: fixture.source.appendingPathComponent("extra.bin"))
                    }
                    _ = try lease.moveToPrivateTrash(input, action: action)
                }
            }
            #expect(
                !FileManager.default.fileExists(
                    atPath: fixture.destination.appendingPathComponent("victim.bin").path))
            await lease.closeAndWait()
        }
    }

    @Test func closeFollowersWaitForTheActualHeldCallbackAndRejectSuccessors() async throws {
        let fixture = try Fixture()
        let lease = try fixture.lease()
        let gate = Gate()
        var finished = 0
        let work = Task {
            try await lease.withAction { action in
                await gate.hold()
                _ = try lease.moveToPrivateTrash(
                    fixture.source.appendingPathComponent("victim.bin"), action: action)
            }
        }
        var closers: [Task<Void, Never>] = []
        do {
            let deadline = ContinuousClock.now + .seconds(2)
            while !gate.entered, ContinuousClock.now < deadline { await Task.yield() }
            try #require(gate.entered)
            lease.closeAdmission()
            for _ in 0..<2 {
                closers.append(
                    Task {
                        await lease.closeAndWait(); finished += 1
                    })
            }
            for _ in 0..<5 { await Task.yield() }
            #expect(finished == 0)
            await #expect(throws: (any Error).self) { try await lease.withAction { _ in () } }
            gate.release()
            try await work.value
            for task in closers { await task.value }
            #expect(finished == 2)
            #expect(
                FileManager.default.fileExists(
                    atPath: fixture.destination.appendingPathComponent("victim.bin").path))
        } catch {
            work.cancel(); gate.release()
            _ = try? await work.value
            for task in closers { await task.value }
            throw error
        }
    }
}
