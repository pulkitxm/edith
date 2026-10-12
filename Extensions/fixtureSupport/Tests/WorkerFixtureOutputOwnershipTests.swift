import Darwin
import Foundation
import Testing
@testable import WorkerFixtureSupport

@MainActor struct WorkerFixtureOutputOwnershipTests {
    @MainActor private final class Currentness {
        var alive = true
        var observations = 0
        func requireCurrent() throws {
            observations += 1
            guard alive else { throw WorkerFixtureError.invalid }
        }
    }

    @MainActor private final class Fixture {
        let root: URL
        let parent: WorkerFixtureUIOpenedPath
        let policy: WorkerFixtureRolePolicy
        let currentness = Currentness()
        let session = UUID().uuidString.lowercased()

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("functional-fixture-" + session, isDirectory: true)
            let directory = root.appendingPathComponent("outputs/studio", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            parent = try WorkerFixtureUIOpenedPath(
                directory, directory: true, mode: 0o700, maximum: nil)
            policy = try WorkerFixtureRolePolicy(
                owner: "studio", primaryRole: .app, operations: ["studio.ui.blob.read"],
                presentations: [
                    try WorkerFixturePresentationScope(location: "main", section: "studio")
                ],
                inputs: [], outputs: (0..<8).map { "studio.ui.blob.\($0)" },
                fileScopes: try (0..<8).map { index in
                    try WorkerFixtureFileScope(
                        name: "studio.ui.blob.\(index)", kind: .file,
                        purpose: .initiallyAbsentOutput, root: .ownerOutputs,
                        components: [.literal("blob-\(index)")], maximumBytes: 16,
                        maximumEntries: 1, initialState: .absent,
                        allowedStates: [.absent, .present], immutableFiles: [], mutableFiles: [])
                }, manifestSHA256: String(repeating: "a", count: 64),
                caseSHA256: String(repeating: "b", count: 64))
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func output(_ index: Int = 0) -> WorkerFixtureEngineOutput {
            WorkerFixtureEngineOutput(
                name: "studio.ui.blob.\(index)", path: parent.url.path + "/blob-\(index)",
                parent: parent.url.path)
        }

        func scope(_ index: Int = 0) throws -> WorkerFixtureEngineOutputScope {
            try WorkerFixtureEngineOutputScope(
                output: output(index), policy: policy, root: root.path, session: session,
                phase: "initial")
        }

        func create(_ index: Int = 0) throws -> WorkerFixtureOutputFile {
            try WorkerFixtureOutputFile(
                output: output(index), parent: parent, scope: scope(index),
                requireAdmission: currentness.requireCurrent)
        }
    }

    @Test func exactEightSlotsRetainBytesAndEnforceSignedBounds() throws {
        let fixture = try Fixture()
        for index in 0..<8 {
            let file = try fixture.create(index)
            #expect(file.name == "studio.ui.blob.\(index)")
            #expect(try file.read(offset: 0, count: 16).isEmpty)
            try file.write(Data([1, 2, 3]), offset: 0)
            try file.write(Data([4, 5]), offset: 3)
            #expect(try file.read(offset: 2, count: 16) == Data([3, 4, 5]))
            #expect(throws: (any Error).self) { try file.write(Data([9]), offset: 6) }
            #expect(throws: (any Error).self) { try file.write(Data(count: 17), offset: 0) }
            #expect(throws: (any Error).self) { try file.read(offset: -1, count: 1) }
            #expect(throws: (any Error).self) { try file.read(offset: 0, count: 17) }
            try file.write(Data(count: 11), offset: 5)
            #expect(try file.read(offset: 0, count: 16).count == 16)
            #expect(throws: (any Error).self) { try file.write(Data([1]), offset: 16) }
            file.close()
        }
        #expect(fixture.currentness.observations > 32)
        #expect(throws: (any Error).self) { try fixture.create(8) }
    }

    @Test func exclusiveCreationDoesNotOverwriteExistingOrFollowSymlink() throws {
        let fixture = try Fixture()
        let path = fixture.output().path
        try Data([7]).write(to: URL(fileURLWithPath: path))
        #expect(throws: (any Error).self) { try fixture.create() }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data([7]))
        try FileManager.default.removeItem(atPath: path)
        let other = fixture.root.appendingPathComponent("unrelated")
        try Data([8]).write(to: other)
        #expect(symlink(other.path, path) == 0)
        #expect(throws: (any Error).self) { try fixture.create() }
        #expect(try Data(contentsOf: other) == Data([8]))
    }

    @Test func sameNamedReplacementCannotBeReadOrWritten() throws {
        let fixture = try Fixture()
        let file = try fixture.create()
        try file.write(Data([1]), offset: 0)
        let path = fixture.output().path
        #expect(unlink(path) == 0)
        try Data([7, 8]).write(to: URL(fileURLWithPath: path))
        #expect(chmod(path, 0o600) == 0)
        #expect(throws: (any Error).self) { try file.read(offset: 0, count: 1) }
        #expect(throws: (any Error).self) { try file.write(Data([9]), offset: 0) }
        #expect(throws: (any Error).self) { try file.write(Data([9]), offset: 0) }
        file.close()
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data([7, 8]))
    }

    @Test func pinnedParentReplacementRejectsFirstMutationAndExistingOwner() throws {
        let fixture = try Fixture()
        let file = try fixture.create()
        let old = fixture.root.appendingPathComponent("old-parent")
        #expect(rename(fixture.parent.url.path, old.path) == 0)
        try FileManager.default.createDirectory(
            at: fixture.parent.url, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        #expect(throws: (any Error).self) { try fixture.create(1) }
        #expect(throws: (any Error).self) { try file.write(Data([1]), offset: 0) }
        #expect(throws: (any Error).self) { try file.write(Data([9]), offset: 0) }
        #expect(!FileManager.default.fileExists(atPath: fixture.output(1).path))
        #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("blob-0").path))
    }

    @Test func closeRetiresOnlyHeldDescriptorAfterValidatedNameIsReplaced() throws {
        let fixture = try Fixture()
        let old = try fixture.create()
        try old.write(Data([1]), offset: 0)
        try old.requireCurrent()
        let path = fixture.output().path
        let moved = fixture.root.appendingPathComponent("original-retained")
        #expect(rename(path, moved.path) == 0)
        try Data([4]).write(to: URL(fileURLWithPath: path))
        #expect(chmod(path, 0o600) == 0)
        old.close()
        old.close()
        #expect(throws: (any Error).self) { try old.requireCurrent() }
        #expect(throws: (any Error).self) { try old.write(Data([9]), offset: 0) }
        #expect(throws: (any Error).self) { try old.read(offset: 0, count: 1) }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data([4]))
        #expect(try Data(contentsOf: moved) == Data([1]))
        #expect(throws: (any Error).self) { try fixture.create() }
    }

    @Test func retainedEightSlotPoolPreservesLogicalReadLengthsForRepeatedTransfers() throws {
        let fixture = try Fixture()
        let slots = try (0..<8).map { try fixture.create($0) }
        for transfer in 0..<80 {
            let file = slots[transfer % slots.count]
            let data = Data(repeating: UInt8(transfer), count: 1 + transfer % 16)
            try file.write(data, offset: 0)
            #expect(try file.read(offset: 0, count: data.count) == data)
            #expect(try file.read(offset: 0, count: 16).count <= 16)
            #expect(throws: (any Error).self) { try file.write(Data(count: 17), offset: 0) }
        }
        for file in slots { file.close() }
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: fixture.parent.url.path).count == 8)
    }

    @Test func expiredAdmissionRejectsEveryOperationAndCreation() throws {
        let fixture = try Fixture()
        let file = try fixture.create()
        try file.write(Data([3]), offset: 0)
        fixture.currentness.alive = false
        #expect(throws: (any Error).self) { try fixture.create(1) }
        #expect(throws: (any Error).self) { try file.read(offset: 0, count: 1) }
        #expect(throws: (any Error).self) { try file.write(Data([9]), offset: 0) }
        #expect(throws: (any Error).self) { try file.write(Data([9]), offset: 0) }
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.output().path)) == Data([3]))
    }

    @Test func changedSizePermissionsAndHardlinkInvalidateOwnedIdentity() throws {
        for change in 0..<3 {
            let fixture = try Fixture()
            let file = try fixture.create()
            let path = fixture.output().path
            switch change {
            case 0:
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                try handle.truncate(atOffset: 17)
                try handle.close()
            case 1: #expect(chmod(path, 0o644) == 0)
            default: #expect(link(path, fixture.root.appendingPathComponent("alias").path) == 0)
            }
            #expect(throws: (any Error).self) { try file.requireCurrent() }
            #expect(throws: (any Error).self) { try file.write(Data([9]), offset: 0) }
        }
    }

    @Test func initialPresenceAndUnnamedOutputCannotAcquireOwner() throws {
        let fixture = try Fixture()
        let scope = try fixture.scope()
        try scope.validate(present: false, bytes: 0, initial: true)
        #expect(throws: (any Error).self) {
            try scope.validate(present: true, bytes: 0, initial: true)
        }
        let unboundedPolicy = try WorkerFixtureRolePolicy(
            owner: "studio", primaryRole: .app, operations: ["studio.ui.blob.read"],
            presentations: [
                try WorkerFixturePresentationScope(location: "main", section: "studio")
            ],
            inputs: [], outputs: ["studio.ui.blob.0"], fileScopes: [],
            manifestSHA256: String(repeating: "a", count: 64),
            caseSHA256: String(repeating: "b", count: 64))
        let unbounded = try WorkerFixtureEngineOutputScope(
            output: fixture.output(), policy: unboundedPolicy, root: fixture.root.path,
            session: fixture.session, phase: "initial")
        #expect(throws: (any Error).self) {
            try WorkerFixtureOutputFile(
                output: fixture.output(), parent: fixture.parent, scope: unbounded,
                requireAdmission: fixture.currentness.requireCurrent)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.output().path))
    }
    @Test func namespaceCloseRetainsActualActionUntilFinish() async throws {
        let currentness = Currentness()
        let lease = WorkerFixtureNamespaceLease(requireAdmission: currentness.requireCurrent)
        let action = try lease.beginAction()
        #expect(throws: (any Error).self) { try lease.beginAction() }
        lease.closeAdmission()
        #expect(throws: (any Error).self) { try lease.beginAction() }
        #expect(throws: (any Error).self) { try lease.requireCurrent() }
        try lease.requireCurrent(action)
        currentness.alive = false
        #expect(throws: (any Error).self) { try lease.requireCurrent(action) }
        try lease.finishAction(action)
        await lease.closeAndWait()
        #expect(throws: (any Error).self) { try lease.finishAction(action) }
        #expect(throws: (any Error).self) { try lease.requireCurrent(action) }
    }

    @Test func namespaceForeignActionCannotReleaseRetainedCallback() throws {
        let currentness = Currentness()
        let first = WorkerFixtureNamespaceLease(requireAdmission: currentness.requireCurrent)
        let second = WorkerFixtureNamespaceLease(requireAdmission: currentness.requireCurrent)
        let action = try first.beginAction()
        #expect(throws: (any Error).self) { try second.requireCurrent(action) }
        #expect(throws: (any Error).self) { try second.finishAction(action) }
        #expect(throws: (any Error).self) { try first.beginAction() }
        try first.finishAction(action)
        let next = try first.beginAction()
        #expect(throws: (any Error).self) { try first.finishAction(action) }
        try first.finishAction(next)
    }

    @Test func namespaceAwaitedBodyIsRetainedAcrossClosure() async throws {
        let currentness = Currentness()
        let lease = WorkerFixtureNamespaceLease(requireAdmission: currentness.requireCurrent)
        let value = try await lease.withAction { action in
            lease.closeAdmission()
            try lease.requireCurrent(action)
            #expect(throws: (any Error).self) { try lease.beginAction() }
            return 17
        }
        #expect(value == 17)
        await lease.closeAndWait()
    }

}
