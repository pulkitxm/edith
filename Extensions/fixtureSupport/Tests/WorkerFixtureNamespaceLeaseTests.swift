import Darwin
import Foundation
import Testing
@testable import WorkerFixtureSupport

@MainActor struct WorkerFixtureNamespaceLeaseTests {
    @MainActor private final class Currentness {
        var alive = true
        func requireCurrent() throws {
            guard alive else { throw WorkerFixtureError.invalid }
        }
    }

    @MainActor private final class Fixture {
        let session = UUID().uuidString.lowercased()
        let root: URL
        let parent: WorkerFixtureUIOpenedPath
        let inputs: [WorkerFixtureUIOpenedPath]
        let current = Currentness()
        let policy: WorkerFixtureRolePolicy
        let engine = WorkerFixtureUIProcess(
            pid: 41, birthSeconds: 10, birthMicroseconds: 20, uid: getuid(),
            executable: "/private/synthetic/Fixture.app/Contents/MacOS/Edith",
            executableSHA256: String(repeating: "a", count: 64))

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("functional-fixture-" + session)
            let output = root.appendingPathComponent("outputs/studio")
            let input = root.appendingPathComponent("inputs/studio")
            for url in [output, input] {
                try FileManager.default.createDirectory(
                    at: url, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            parent = try WorkerFixtureUIOpenedPath(
                output, directory: true, mode: 0o700, maximum: nil)
            inputs = try (0..<2).map { index in
                let url = input.appendingPathComponent("input-\(index)")
                try Data([UInt8(index + 1)]).write(to: url)
                guard chmod(url.path, 0o600) == 0 else { throw WorkerFixtureError.invalid }
                return try WorkerFixtureUIOpenedPath(
                    url, directory: false, mode: 0o600, maximum: 16)
            }
            policy = try WorkerFixtureRolePolicy(
                owner: "studio", primaryRole: .app, operations: ["studio.ui.video.export"],
                presentations: [
                    try WorkerFixturePresentationScope(location: "main", section: "studio")
                ],
                inputs: [], outputs: ["stage", "publication"],
                fileScopes: try ["stage", "publication"].map { name in
                    try WorkerFixtureFileScope(
                        name: name, kind: .file, purpose: .initiallyAbsentOutput,
                        root: .ownerOutputs, components: [.literal(name)], maximumBytes: 16,
                        maximumEntries: 1, initialState: .absent,
                        allowedStates: [.absent, .present], immutableFiles: [], mutableFiles: [])
                }, manifestSHA256: String(repeating: "a", count: 64),
                caseSHA256: String(repeating: "b", count: 64))
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func output(_ name: String) -> WorkerFixtureEngineOutput {
            WorkerFixtureEngineOutput(
                name: name, path: parent.url.path + "/" + name, parent: parent.url.path)
        }

        func makeExport() throws -> WorkerFixtureNativeExportLease {
            try WorkerFixtureNativeExportLease(
                stage: output("stage"), publication: output("publication"),
                stageParent: parent, publicationParent: parent,
                stageScope: WorkerFixtureEngineOutputScope(
                    output: output("stage"), policy: policy, root: root.path, session: session,
                    phase: "initial"),
                publicationScope: WorkerFixtureEngineOutputScope(
                    output: output("publication"), policy: policy, root: root.path,
                    session: session, phase: "initial"),
                engine: engine,
                requireAdmission: { [self] in
                    try current.requireCurrent()
                    for file in inputs { _ = try file.read() }
                })
        }

        func seed(_ path: String, bytes: Data = Data([1, 2, 3])) throws {
            try bytes.write(to: URL(fileURLWithPath: path))
            guard chmod(path, 0o600) == 0 else { throw WorkerFixtureError.invalid }
        }
    }

    @Test func firstWriteGrantPrecedesCreationAndPublishesExactHeldInode() async throws {
        let fixture = try Fixture()
        let lease = try fixture.makeExport()
        #expect(lease.engine == fixture.engine)
        let result = try await lease.withAction { action in
            let stage = try lease.stageURL(action)
            #expect(!FileManager.default.fileExists(atPath: stage.path))
            #expect(throws: (any Error).self) { try lease.stageURL(action) }
            try fixture.seed(stage.path)
            var before = stat()
            #expect(lstat(stage.path, &before) == 0)
            lease.closeAdmission()
            let output = try lease.publish(action)
            var after = stat()
            #expect(lstat(output.path, &after) == 0)
            #expect(before.st_ino == after.st_ino && before.st_dev == after.st_dev)
            #expect(!FileManager.default.fileExists(atPath: stage.path))
            #expect(throws: (any Error).self) { try lease.publish(action) }
            return try Data(contentsOf: output)
        }
        #expect(result == Data([1, 2, 3]))
        await lease.closeAndWait()
        await #expect(throws: (any Error).self) { try await lease.withAction { _ in 1 } }
    }

    @Test func actualCallbackReturnIsRequiredBeforeCloseWaitCompletes() async throws {
        let fixture = try Fixture()
        let lease = try fixture.makeExport()
        var callback: CheckedContinuation<Void, Never>?
        var started = false
        var joined = false
        let writer = Task { @MainActor in
            try await lease.withAction { action in
                let stage = try lease.stageURL(action)
                started = true
                await withCheckedContinuation { callback = $0 }
                try fixture.seed(stage.path)
                _ = try lease.publish(action)
            }
        }
        while !started { await Task.yield() }
        let closer = Task { @MainActor in
            await lease.closeAndWait(); joined = true
        }
        for _ in 0..<5 { await Task.yield() }
        #expect(!joined)
        callback!.resume()
        try await writer.value
        await closer.value
        #expect(joined)
    }

    @Test func expiredInputsParentReplacementAndDestinationCollisionRejectBeforePublication()
        async throws
    {
        for change in 0..<4 {
            let fixture = try Fixture()
            let lease = try fixture.makeExport()
            await #expect(throws: (any Error).self) {
                try await lease.withAction { action in
                    let stage = try lease.stageURL(action)
                    try fixture.seed(stage.path)
                    switch change {
                    case 0: fixture.current.alive = false
                    case 1: try fixture.seed(fixture.inputs[0].url.path, bytes: Data([7]))
                    case 2: try fixture.seed(fixture.output("publication").path, bytes: Data([9]))
                    default:
                        #expect(
                            rename(
                                fixture.parent.url.path,
                                fixture.root.appendingPathComponent("old").path) == 0)
                        try FileManager.default.createDirectory(
                            at: fixture.parent.url, withIntermediateDirectories: false,
                            attributes: [.posixPermissions: 0o700])
                    }
                    _ = try lease.publish(action)
                }
            }
            await lease.closeAndWait()
            if change == 2 {
                #expect(
                    try Data(contentsOf: URL(fileURLWithPath: fixture.output("publication").path))
                        == Data([9]))
            }
        }
    }

    @Test func foreignActionAndOversizeHardlinkSymlinkCannotPublish() async throws {
        for change in 0..<4 {
            let fixture = try Fixture()
            let lease = try fixture.makeExport()
            let foreign = WorkerFixtureNamespaceLease(
                requireAdmission: fixture.current.requireCurrent)
            let action = try foreign.beginAction()
            #expect(throws: (any Error).self) { try lease.stageURL(action) }
            try foreign.finishAction(action)
            await #expect(throws: (any Error).self) {
                try await lease.withAction { action in
                    let stage = try lease.stageURL(action)
                    switch change {
                    case 0: try fixture.seed(stage.path, bytes: Data(count: 17))
                    case 1:
                        try fixture.seed(stage.path)
                        #expect(
                            link(stage.path, fixture.root.appendingPathComponent("alias").path) == 0
                        )
                    case 2: #expect(symlink(fixture.inputs[0].url.path, stage.path) == 0)
                    default: try fixture.seed(stage.path, bytes: Data())
                    }
                    _ = try lease.publish(action)
                }
            }
            await lease.closeAndWait()
            #expect(!FileManager.default.fileExists(atPath: fixture.output("publication").path))
        }
    }

    @MainActor private final class TrashFixture {
        let session = UUID().uuidString.lowercased()
        let root: URL
        let source: URL
        let destination: URL
        let current = Currentness()
        let lease: WorkerFixtureCooperativeNamespaceLease

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("functional-fixture-" + session)
            source = root.appendingPathComponent("blitztree-home/source")
            destination = root.appendingPathComponent("outputs/blitztree/trash")
            for url in [source, destination] {
                try FileManager.default.createDirectory(
                    at: url, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            for (name, bytes) in [
                ("selected.txt", Data([1, 2])), ("retained.txt", Data([3, 4, 5])),
            ] {
                let path = source.appendingPathComponent(name)
                try bytes.write(to: path)
                guard chmod(path.path, 0o600) == 0 else { throw WorkerFixtureError.invalid }
            }
            let policy = try WorkerFixtureRolePolicy(
                owner: "blitztree", primaryRole: .app, operations: ["blitztree.ui.trash"],
                presentations: [
                    try WorkerFixturePresentationScope(location: "main", section: "blitztree")
                ],
                inputs: [], outputs: [],
                fileScopes: try [false, true].map { target in
                    try WorkerFixtureFileScope(
                        name: target ? "trash-directory" : "scan-root", kind: .directory,
                        purpose: .mutableState, root: target ? .ownerOutputs : .ownerHome,
                        components: [.literal(target ? "trash" : "source")],
                        maximumBytes: 32, maximumEntries: 2, initialState: .present,
                        allowedStates: [.present], immutableFiles: [],
                        mutableFiles: try ["selected.txt", "retained.txt"].map { name in
                            try WorkerFixtureMutableFileScope(
                                components: [name], maximumBytes: 16,
                                initialState: target ? .absent : .present,
                                allowedStates: [.present, .absent])
                        })
                }, manifestSHA256: String(repeating: "a", count: 64),
                caseSHA256: String(repeating: "b", count: 64))
            let scopes = try policy.resolvedOwnedPaths(
                root: root.path, session: session, phase: .initial)
            lease = try WorkerFixtureCooperativeNamespaceLease(
                source: scopes[0], destination: scopes[1],
                engine: WorkerFixtureUIProcess(
                    pid: 41, birthSeconds: 10, birthMicroseconds: 20, uid: getuid(),
                    executable: "/private/synthetic/Fixture.app/Contents/MacOS/Edith",
                    executableSHA256: String(repeating: "a", count: 64)),
                requireAdmission: current.requireCurrent)
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    @Test func originalTrashMoverConsumesOnlyCapturedLeafAndRetainsOtherInput() async throws {
        let fixture = try TrashFixture()
        let input = fixture.source.appendingPathComponent("selected.txt")
        var before = stat()
        #expect(lstat(input.path, &before) == 0)
        let target = try await fixture.lease.withAction { action in
            fixture.lease.closeAdmission()
            let target = try fixture.lease.moveToPrivateTrash(input, action: action)
            #expect(throws: (any Error).self) {
                try fixture.lease.moveToPrivateTrash(input, action: action)
            }
            return target
        }
        var after = stat()
        #expect(lstat(target.path, &after) == 0)
        #expect(before.st_ino == after.st_ino && before.st_dev == after.st_dev)
        #expect(!FileManager.default.fileExists(atPath: input.path))
        #expect(try Data(contentsOf: target) == Data([1, 2]))
        #expect(
            try Data(contentsOf: fixture.source.appendingPathComponent("retained.txt"))
                == Data([3, 4, 5]))
        await fixture.lease.closeAndWait()
        await #expect(throws: (any Error).self) { try await fixture.lease.withAction { _ in 1 } }
    }

    @Test func privateTrashRejectsInputMutationCollisionForeignPathAndParentReplacement()
        async throws
    {
        for change in 0..<5 {
            let fixture = try TrashFixture()
            let selected = fixture.source.appendingPathComponent("selected.txt")
            await #expect(throws: (any Error).self) {
                try await fixture.lease.withAction { action in
                    var candidate = selected
                    switch change {
                    case 0:
                        try Data([9]).write(to: selected)
                        #expect(chmod(selected.path, 0o600) == 0)
                    case 1:
                        let target = fixture.destination.appendingPathComponent("selected.txt")
                        try Data([8]).write(to: target)
                        #expect(chmod(target.path, 0o600) == 0)
                    case 2: candidate = fixture.root.appendingPathComponent("unbound")
                    case 3:
                        #expect(
                            rename(
                                fixture.source.path,
                                fixture.root.appendingPathComponent("old-source").path) == 0)
                        try FileManager.default.createDirectory(
                            at: fixture.source, withIntermediateDirectories: false,
                            attributes: [.posixPermissions: 0o700])
                    default: fixture.current.alive = false
                    }
                    _ = try fixture.lease.moveToPrivateTrash(candidate, action: action)
                }
            }
            await fixture.lease.closeAndWait()
            if change == 1 {
                #expect(
                    try Data(contentsOf: fixture.destination.appendingPathComponent("selected.txt"))
                        == Data([8]))
            }
        }
    }

    @Test func processLifetimeGrantsRejectReconstructionAndOverlappingNamespaces() throws {
        let book = WorkerFixtureNamespaceGrantBook()
        try book.retain([
            "/private/synthetic/stage": false, "/private/synthetic/publication": false,
        ])
        #expect(throws: (any Error).self) { try book.retain(["/private/synthetic/stage": false]) }
        #expect(throws: (any Error).self) { try book.retain(["/private/synthetic": true]) }
        try book.retain(["/private/synthetic/trash": true])
        #expect(throws: (any Error).self) {
            try book.retain(["/private/synthetic/trash/leaf": false])
        }
        #expect(throws: (any Error).self) { try book.retain(["/private/synthetic/Trash": true]) }
        #expect(throws: (any Error).self) {
            try book.retain(["/private/synthetic/new": true, "/private/synthetic/new/leaf": false])
        }
        try book.retain(["/private/synthetic/unrelated": false])
    }

    @Test func closedNamespaceReleasesAuthorityOnlyAfterRetainedCallbackReturns() throws {
        var current: Currentness? = Currentness()
        weak var retained = current
        let lease = WorkerFixtureNamespaceLease(requireAdmission: { [value = current!] in
            try value.requireCurrent()
        })
        current = nil
        #expect(retained != nil)
        let action = try lease.beginAction()
        lease.closeAdmission()
        #expect(retained != nil)
        try lease.requireCurrent(action)
        try lease.finishAction(action)
        #expect(retained == nil)
        #expect(throws: (any Error).self) { try lease.requireCurrent(action) }
    }

}
