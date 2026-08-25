import Foundation
import Testing

@testable import EdithKit

@Suite struct UsageSnapshotStoreTests {
    private enum InjectedFailure: Error {
        case stop
    }

    private struct Fixture {
        let directory: URL
        let data: URL
        let snapshots: URL

        var source: UsageSnapshotSource {
            UsageSnapshotSource(dataDirectory: data)
        }
    }

    private static let usage: Data = {
        let hours: [[String: Any]] = (0..<24).map {
            ["hour": $0, "cost": 0, "tokens": 0, "bySource": [:], "byPath": [:]]
        }
        return try! JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 8,
                "generatedAt": "2026-08-25T00:00:00Z",
                "sources": ["codex"],
                "defaultSources": ["codex"],
                "sourceMeta": ["codex": ["label": "Codex", "tool": "codex"]],
                "sessions": [],
                "totals": [
                    "cost": 0, "tokens": 1, "inputTokens": 1, "outputTokens": 0,
                    "cacheCreationTokens": 0, "cacheReadTokens": 0,
                    "bySource": ["codex": ["cost": 0, "tokens": 1]],
                ],
                "daily": [
                    [
                        "period": "2026-08-25",
                        "bySource": [
                            "codex": [
                                [
                                    "modelName": "gpt", "inputTokens": 1,
                                    "outputTokens": 0, "cacheCreationTokens": 0,
                                    "cacheReadTokens": 0, "cost": 0,
                                ]
                            ]
                        ],
                        "hours": hours, "projects": [],
                    ]
                ],
            ])
    }()

    private static func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-snapshot-\(UUID().uuidString)")
        let data = directory.appendingPathComponent("data")
        let snapshots = directory.appendingPathComponent("snapshots")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        return Fixture(directory: directory, data: data, snapshots: snapshots)
    }

    private static func populate(_ fixture: Fixture, machine: Machine? = nil) throws {
        try usage.write(to: fixture.source.usageFile)
        let first = LimitsHistory.row(
            provider: .claude, session: LimitWindow(percent: 25, resetsAt: nil), week: nil,
            now: Date(timeIntervalSince1970: 1_777_248_000))
        let second = LimitsHistory.row(
            provider: .codex, session: nil, week: LimitWindow(percent: 50, resetsAt: nil),
            now: Date(timeIntervalSince1970: 1_777_248_060))
        try Data((first.line + second.line).utf8).write(to: fixture.source.limitsFile)
        if let machine {
            _ = try MachineUsageStore.save(
                document: usage, machine: machine, slug: machine.name, host: machine.host,
                collectedAt: Date(timeIntervalSince1970: 1_777_248_120),
                in: fixture.source.machinesDirectory)
        }
    }

    @Test func publicationCapturesOnlyValidatedImmutableInputs() async throws {
        let fixture = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let machine = Machine(id: UUID(), name: "build-box", host: "build.local")
        try Self.populate(fixture, machine: machine)
        try Data("private log".utf8).write(to: fixture.data.appendingPathComponent("refresh.log"))
        let identifier = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_777_248_300)
        let store = UsageSnapshotStore(source: fixture.source, root: fixture.snapshots)

        let published = try await store.publish(generation: identifier, createdAt: createdAt)

        #expect(UsageHistory.isValidDocument(Self.usage))
        #expect(published.manifest.formatVersion == 1)
        #expect(published.manifest.generation == identifier.uuidString.lowercased())
        #expect(published.manifest.createdAt == createdAt)
        #expect(
            published.manifest.files.map(\.path)
                == [
                    "limits-history.jsonl",
                    "machines/\(machine.id.uuidString.lowercased()).json",
                    "usage.json",
                ])
        #expect(
            !FileManager.default.fileExists(
                atPath: published.directory.appendingPathComponent("refresh.log").path))
        let snapshotUsage = published.directory.appendingPathComponent("usage.json")
        let before = try Data(contentsOf: snapshotUsage)
        try Data("changed".utf8).write(to: fixture.source.usageFile)
        #expect(try Data(contentsOf: snapshotUsage) == before)
        #expect(try await store.current() == published)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.snapshots.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
    }

    @Test func corruptUsageAndMachineInputsNeverMoveThePointer() async throws {
        let fixture = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Self.populate(fixture)
        let first = UUID()
        let store = UsageSnapshotStore(source: fixture.source, root: fixture.snapshots)
        _ = try await store.publish(generation: first)

        try Data("not json".utf8).write(to: fixture.source.usageFile)
        await #expect(throws: UsageSnapshotError.invalidUsage(fixture.source.usageFile.path)) {
            try await store.publish(generation: UUID())
        }
        #expect(try await store.current()?.manifest.generation == first.uuidString.lowercased())

        try Self.usage.write(to: fixture.source.usageFile)
        let machineID = UUID()
        try FileManager.default.createDirectory(
            at: fixture.source.machinesDirectory, withIntermediateDirectories: true)
        let invalidMachine = fixture.source.machinesDirectory
            .appendingPathComponent("\(machineID.uuidString).json")
        try Self.usage.write(to: invalidMachine)
        await #expect(throws: UsageSnapshotError.invalidMachine(invalidMachine.path)) {
            try await store.publish(generation: UUID())
        }
        #expect(try await store.current()?.manifest.generation == first.uuidString.lowercased())
    }

    @Test func finalTornLimitRowIsDroppedButInteriorCorruptionIsRejected() async throws {
        let fixture = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Self.populate(fixture)
        let handle = try FileHandle(forWritingTo: fixture.source.limitsFile)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"ts\":\"torn".utf8))
        try handle.close()
        let store = UsageSnapshotStore(source: fixture.source, root: fixture.snapshots)
        let first = try await store.publish(generation: UUID())
        let snapshotted = try String(
            contentsOf: first.directory.appendingPathComponent("limits-history.jsonl"),
            encoding: .utf8)
        #expect(!snapshotted.contains("torn"))
        #expect(snapshotted.split(separator: "\n").count == 2)

        let invalid =
            LimitsHistory.row(
                session: LimitWindow(percent: 10, resetsAt: nil), week: nil,
                now: Date(timeIntervalSince1970: 1_777_248_900)
            ).line + "broken\n"
        try Data(invalid.utf8).write(to: fixture.source.limitsFile)
        await #expect(throws: UsageSnapshotError.invalidLimits(fixture.source.limitsFile.path)) {
            try await store.publish(generation: UUID())
        }
        #expect(try await store.current() == first)
    }

    @Test func stagingAndPointerInterruptionsPreserveThePublishedGeneration() async throws {
        let fixture = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Self.populate(fixture)
        let firstID = UUID()
        let live = UsageSnapshotStore(source: fixture.source, root: fixture.snapshots)
        let first = try await live.publish(generation: firstID)

        let stagingID = UUID()
        let stagingInterrupted = UsageSnapshotStore(
            source: fixture.source, root: fixture.snapshots,
            hooks: UsageSnapshotHooks(afterStagingFile: { _ in throw InjectedFailure.stop }))
        await #expect(throws: InjectedFailure.stop) {
            try await stagingInterrupted.publish(generation: stagingID)
        }
        #expect(try await live.current() == first)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.snapshots.appendingPathComponent(
                    "generations/\(stagingID.uuidString.lowercased())"
                ).path))

        let promotedID = UUID()
        let pointerInterrupted = UsageSnapshotStore(
            source: fixture.source, root: fixture.snapshots,
            hooks: UsageSnapshotHooks(beforePointerPublication: { throw InjectedFailure.stop }))
        await #expect(throws: InjectedFailure.stop) {
            try await pointerInterrupted.publish(generation: promotedID)
        }
        #expect(try await live.current() == first)
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.snapshots.appendingPathComponent(
                    "generations/\(promotedID.uuidString.lowercased())"
                ).path))
    }

    @Test func successfulPublicationRetainsExactlyCurrentAndPrevious() async throws {
        let fixture = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Self.populate(fixture)
        let store = UsageSnapshotStore(source: fixture.source, root: fixture.snapshots)
        let identifiers = [UUID(), UUID(), UUID()]
        for identifier in identifiers {
            _ = try await store.publish(generation: identifier)
        }

        let current = try #require(try await store.current())
        #expect(current.manifest.generation == identifiers[2].uuidString.lowercased())
        #expect(current.previousGeneration == identifiers[1].uuidString.lowercased())
        let directories = try FileManager.default.contentsOfDirectory(
            at: fixture.snapshots.appendingPathComponent("generations"),
            includingPropertiesForKeys: nil)
        #expect(
            Set(directories.map(\.lastPathComponent))
                == Set(identifiers.suffix(2).map { $0.uuidString.lowercased() }))
    }

    @Test func currentGenerationDetectsPayloadCorruptionAndUnexpectedFiles() async throws {
        let fixture = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Self.populate(fixture)
        let identifier = UUID()
        let store = UsageSnapshotStore(source: fixture.source, root: fixture.snapshots)
        let publication = try await store.publish(generation: identifier)
        try Data("corrupt".utf8).write(
            to: publication.directory.appendingPathComponent("usage.json"))
        await #expect(
            throws: UsageSnapshotError.corruptGeneration(identifier.uuidString.lowercased())
        ) {
            try await store.current()
        }

        try Self.populate(fixture)
        let next = try await store.publish(generation: UUID())
        try Data("extra".utf8).write(to: next.directory.appendingPathComponent("credentials.json"))
        await #expect(throws: UsageSnapshotError.corruptGeneration(next.manifest.generation)) {
            try await store.current()
        }
    }

    @Test func snapshotSerializesWithAppendSaveAndForgetMutations() async throws {
        let fixture = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let forgotten = Machine(id: UUID(), name: "old", host: "old.local")
        let saved = Machine(id: UUID(), name: "new", host: "new.local")
        try Self.populate(fixture, machine: forgotten)
        let held = try UsageDataLock.acquire(dataDirectory: fixture.data)
        let identifier = UUID()
        let store = UsageSnapshotStore(source: fixture.source, root: fixture.snapshots)
        let publicationTask = Task {
            try await store.publish(generation: identifier)
        }
        let transactionLock = UsageRefreshRunner.transactionURL(dataDir: fixture.data)
        for _ in 0..<1_000 where !UsageRefreshLock.isHeld(at: transactionLock) {
            await Task.yield()
        }
        #expect(UsageRefreshLock.isHeld(at: transactionLock))

        let appendTask = Task.detached {
            var history = LimitsHistory(url: fixture.source.limitsFile)
            history.append(
                session: LimitWindow(percent: 75, resetsAt: nil), week: nil,
                now: Date(timeIntervalSince1970: 1_777_249_000))
        }
        let saveTask = Task.detached {
            _ = try MachineUsageStore.save(
                document: Self.usage, machine: saved, slug: saved.name, host: saved.host,
                collectedAt: Date(), in: fixture.source.machinesDirectory)
        }
        let forgetTask = Task.detached {
            MachineUsageStore.forget(
                machineID: forgotten.id, in: fixture.source.machinesDirectory)
        }
        held.release()
        let publication = try await publicationTask.value
        await appendTask.value
        _ = try await saveTask.value
        _ = await forgetTask.value

        #expect(publication.manifest.generation == identifier.uuidString.lowercased())
        #expect(try await store.current() == publication)
    }

    @Test func activeRefreshAndSymlinkedDestinationAreRejected() async throws {
        let fixture = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Self.populate(fixture)
        let refresh = try #require(
            UsageRefreshLock.acquire(at: UsageRefreshRunner.transactionURL(dataDir: fixture.data)))
        let store = UsageSnapshotStore(source: fixture.source, root: fixture.snapshots)
        await #expect(throws: UsageSnapshotError.refreshBusy) {
            try await store.publish(generation: UUID())
        }
        refresh.release()

        let outside = fixture.directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let victim = outside.appendingPathComponent("victim")
        try Data("safe".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(
            at: fixture.snapshots, withDestinationURL: outside)
        await #expect(throws: UsageSnapshotError.unsafeFile(fixture.snapshots.path)) {
            try await store.publish(generation: UUID())
        }
        #expect(try String(contentsOf: victim, encoding: .utf8) == "safe")
    }
}
