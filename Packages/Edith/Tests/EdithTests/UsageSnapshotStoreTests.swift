import Foundation
import Testing

@testable import EdithKit

private final class UsageSnapshotPublishGate: @unchecked Sendable {
    private let firstCaptured = DispatchSemaphore(value: 0)
    private let releaseFirst = DispatchSemaphore(value: 0)
    private let secondReachedPointer = DispatchSemaphore(value: 0)
    private let mutationStarted = DispatchSemaphore(value: 0)
    private let mutationFinished = DispatchSemaphore(value: 0)

    func blockFirstCapture() throws {
        firstCaptured.signal()
        guard releaseFirst.wait(timeout: .now() + 5) == .success else {
            throw CocoaError(.userCancelled)
        }
    }

    func waitForFirstCapture() async -> Bool {
        await Task.detached { self.waitForFirstCaptureSynchronously() }.value
    }

    func release() {
        releaseFirst.signal()
    }

    func markSecondPointer() {
        secondReachedPointer.signal()
    }

    func secondReachedPointerEarly() async -> Bool {
        await Task.detached { self.secondReachedPointerSynchronously() }.value
    }

    private func waitForFirstCaptureSynchronously() -> Bool {
        firstCaptured.wait(timeout: .now() + 5) == .success
    }

    private func secondReachedPointerSynchronously() -> Bool {
        secondReachedPointer.wait(timeout: .now() + 1) == .success
    }

    func markMutationStarted() {
        mutationStarted.signal()
    }

    func markMutationFinished() {
        mutationFinished.signal()
    }

    func waitForMutationStarts(_ count: Int) async -> Bool {
        await Task.detached { self.waitForMutationStartsSynchronously(count) }.value
    }

    func mutationFinishedEarly() async -> Bool {
        await Task.detached {
            self.mutationFinishedSynchronously()
        }.value
    }

    private func waitForMutationStartsSynchronously(_ count: Int) -> Bool {
        for _ in 0..<count where mutationStarted.wait(timeout: .now() + 5) != .success {
            return false
        }
        return true
    }

    private func mutationFinishedSynchronously() -> Bool {
        mutationFinished.wait(timeout: .now() + 1) == .success
    }
}

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

    private static let usage = usageDocument(
        generatedAt: "2026-08-25T00:00:00Z", period: "2026-08-25")

    private static func usageDocument(generatedAt: String, period: String) -> Data {
        let hours: [[String: Any]] = (0..<24).map {
            ["hour": $0, "cost": 0, "tokens": 0, "bySource": [:], "byPath": [:]]
        }
        return try! JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 8,
                "generatedAt": generatedAt,
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
                        "period": period,
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
    }

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

    @Test func oversizedPreservedLimitTailDoesNotBlockLaterPublication() async throws {
        let fixture = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Self.populate(fixture)
        let oversized = Data(repeating: UInt8(ascii: "x"), count: 1_048_577)
        let handle = try FileHandle(forWritingTo: fixture.source.limitsFile)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: oversized)
        try handle.close()
        var history = LimitsHistory(url: fixture.source.limitsFile)
        history.append(
            provider: .claude, session: LimitWindow(percent: 75, resetsAt: nil), week: nil,
            now: Date(timeIntervalSince1970: 1_777_248_900))
        let source = try Data(contentsOf: fixture.source.limitsFile)
        #expect(source.range(of: oversized) != nil)

        let store = UsageSnapshotStore(source: fixture.source, root: fixture.snapshots)
        let publication = try await store.publish(generation: UUID())
        let text = try String(
            contentsOf: publication.directory.appendingPathComponent("limits-history.jsonl"),
            encoding: .utf8)

        #expect(LimitsHistory.isValidDocument(text))
        #expect(text.utf8.count < oversized.count)
        #expect(LimitsHistory.parse(text, provider: .claude).map(\.s) == [25, 75])
        #expect(LimitsHistory.parse(text, provider: .codex).map(\.w) == [50])
        #expect(try await store.current() == publication)
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

    @Test func blockedFirstPublisherOwnsCaptureThroughPublication() async throws {
        let fixture = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Self.populate(fixture)
        let gate = UsageSnapshotPublishGate()
        defer { gate.release() }
        let firstID = UUID()
        let secondID = UUID()
        let firstStore = UsageSnapshotStore(
            source: fixture.source, root: fixture.snapshots,
            hooks: UsageSnapshotHooks(afterCapture: { try gate.blockFirstCapture() }))
        let secondStore = UsageSnapshotStore(
            source: fixture.source, root: fixture.snapshots,
            hooks: UsageSnapshotHooks(
                beforePointerPublication: { gate.markSecondPointer() }))
        let firstTask = Task.detached {
            try await firstStore.publish(generation: firstID)
        }
        #expect(await gate.waitForFirstCapture())
        let replacement = Self.usageDocument(
            generatedAt: "2026-08-26T00:00:00Z", period: "2026-08-26")
        try replacement.write(to: fixture.source.usageFile)
        let secondTask = Task.detached {
            try await secondStore.publish(generation: secondID)
        }
        let secondReachedPointerEarly = await gate.secondReachedPointerEarly()
        #expect(!secondReachedPointerEarly)
        gate.release()
        let first = try await firstTask.value
        let second = try await secondTask.value

        #expect(try await secondStore.current() == second)
        #expect(first.manifest.generation == firstID.uuidString.lowercased())
        #expect(second.previousGeneration == firstID.uuidString.lowercased())
        #expect(
            try String(
                contentsOf: first.directory.appendingPathComponent("usage.json"),
                encoding: .utf8
            ).contains("2026-08-25"))
        #expect(
            try String(
                contentsOf: second.directory.appendingPathComponent("usage.json"),
                encoding: .utf8
            ).contains("2026-08-26"))
    }

    @Test func corruptCurrentFallsBackAndRepairsThePointer() async throws {
        let fixture = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Self.populate(fixture)
        let store = UsageSnapshotStore(source: fixture.source, root: fixture.snapshots)
        let first = try await store.publish(generation: UUID())
        let second = try await store.publish(generation: UUID())
        try Data("corrupt".utf8).write(
            to: second.directory.appendingPathComponent("usage.json"))

        let recovered = try #require(try await store.current())

        #expect(recovered.manifest.generation == first.manifest.generation)
        #expect(recovered.previousGeneration == nil)
        let pointerData = try Data(
            contentsOf: fixture.snapshots.appendingPathComponent("current.json"))
        let pointer = try JSONDecoder().decode(UsageSnapshotPointer.self, from: pointerData)
        #expect(pointer.current == first.manifest.generation)
        #expect(pointer.previous == nil)
        let generations = try FileManager.default.contentsOfDirectory(
            at: fixture.snapshots.appendingPathComponent("generations"),
            includingPropertiesForKeys: nil)
        #expect(generations.map(\.lastPathComponent) == [first.manifest.generation])
    }

    @Test func validPreviousIsReturnedWhenPointerRepairFails() async throws {
        let fixture = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Self.populate(fixture)
        let live = UsageSnapshotStore(source: fixture.source, root: fixture.snapshots)
        let first = try await live.publish(generation: UUID())
        let second = try await live.publish(generation: UUID())
        try Data("corrupt".utf8).write(
            to: second.directory.appendingPathComponent("usage.json"))
        let failingRepair = UsageSnapshotStore(
            source: fixture.source, root: fixture.snapshots,
            hooks: UsageSnapshotHooks(beforePointerRepair: { throw InjectedFailure.stop }))

        let recovered = try #require(try await failingRepair.current())

        #expect(recovered.manifest.generation == first.manifest.generation)
        let pointerData = try Data(
            contentsOf: fixture.snapshots.appendingPathComponent("current.json"))
        let pointer = try JSONDecoder().decode(UsageSnapshotPointer.self, from: pointerData)
        #expect(pointer.current == second.manifest.generation)
        #expect(pointer.previous == first.manifest.generation)
    }

    @Test func generationDirectorySymlinkIsRejectedWithoutTouchingItsVictim() async throws {
        let fixture = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Self.populate(fixture)
        let store = UsageSnapshotStore(source: fixture.source, root: fixture.snapshots)
        let publication = try await store.publish(generation: UUID())
        let outside = fixture.directory.appendingPathComponent("outside-generation")
        try FileManager.default.moveItem(at: publication.directory, to: outside)
        let victim = outside.appendingPathComponent("victim")
        try Data("safe".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(
            at: publication.directory, withDestinationURL: outside)

        await #expect(throws: UsageSnapshotError.self) {
            try await store.current()
        }
        #expect(try String(contentsOf: victim, encoding: .utf8) == "safe")
        let values = try publication.directory.resourceValues(forKeys: [.isSymbolicLinkKey])
        #expect(values.isSymbolicLink == true)
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

    @Test func promotedGenerationIsValidatedBeforePointerPublication() async throws {
        let fixture = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Self.populate(fixture)
        let live = UsageSnapshotStore(source: fixture.source, root: fixture.snapshots)
        let first = try await live.publish(generation: UUID())
        let identifier = UUID()
        let generation = identifier.uuidString.lowercased()
        let corrupting = UsageSnapshotStore(
            source: fixture.source, root: fixture.snapshots,
            hooks: UsageSnapshotHooks(afterStagingFile: { path in
                guard path == "usage.json" else { return }
                let target = fixture.snapshots.appendingPathComponent(
                    "generations/.pending-\(generation)/usage.json")
                try Data("corrupt".utf8).write(to: target)
            }))

        await #expect(throws: UsageSnapshotError.corruptGeneration(generation)) {
            try await corrupting.publish(generation: identifier)
        }
        #expect(try await live.current() == first)
    }

    @Test func snapshotProjectionDropsEveryUnknownField() async throws {
        let fixture = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var object = try #require(
            try JSONSerialization.jsonObject(with: Self.usage) as? [String: Any])
        object["credential"] = "root-secret"
        var daily = try #require(object["daily"] as? [[String: Any]])
        daily[0]["credential"] = "day-secret"
        daily[0]["bySource"] = [
            "codex": [
                [
                    "modelName": "gpt", "inputTokens": 1, "outputTokens": 0,
                    "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": 0,
                    "credential": "model-secret",
                ]
            ]
        ]
        object["daily"] = daily
        let injected = try JSONSerialization.data(withJSONObject: object)
        try injected.write(to: fixture.source.usageFile)
        let machine = Machine(id: UUID(), name: "build", host: "build.local")
        _ = try MachineUsageStore.save(
            document: injected, machine: machine, slug: machine.name, host: machine.host,
            collectedAt: Date(), in: fixture.source.machinesDirectory)
        let store = UsageSnapshotStore(source: fixture.source, root: fixture.snapshots)

        let publication = try await store.publish(generation: UUID())

        for file in publication.manifest.files where file.path.hasSuffix(".json") {
            let text = try String(
                contentsOf: publication.directory.appendingPathComponent(file.path),
                encoding: .utf8)
            #expect(!text.contains("credential"))
            #expect(!text.contains("secret"))
        }
    }

    @Test func processDeathAtPublicationBoundariesPreservesCurrent() async throws {
        for point in ["staging", "pointer"] {
            let fixture = try Self.fixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            try Self.populate(fixture)
            let store = UsageSnapshotStore(source: fixture.source, root: fixture.snapshots)
            let first = try await store.publish(generation: UUID())
            let interruptedID = UUID()

            let termination = try await Task.detached {
                try Self.runCrashDriver(
                    dataDirectory: fixture.data, root: fixture.snapshots,
                    generation: interruptedID, point: point)
            }.value

            #expect(termination.reason == .uncaughtSignal)
            #expect(termination.status == SIGKILL)
            #expect(try await store.current() == first)
            let replacement = try await store.publish(generation: UUID())
            #expect(try await store.current() == replacement)
            let entries = try FileManager.default.contentsOfDirectory(
                at: fixture.snapshots.appendingPathComponent("generations"),
                includingPropertiesForKeys: nil)
            #expect(
                Set(entries.map(\.lastPathComponent))
                    == Set([first.manifest.generation, replacement.manifest.generation]))
        }
    }

    @Test func snapshotSerializesWithAppendSaveAndForgetMutations() async throws {
        let fixture = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let forgotten = Machine(id: UUID(), name: "old", host: "old.local")
        let saved = Machine(id: UUID(), name: "new", host: "new.local")
        try Self.populate(fixture, machine: forgotten)
        let held = try UsageDataLock.acquire(dataDirectory: fixture.data)
        let gate = UsageSnapshotPublishGate()
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
            gate.markMutationStarted()
            defer { gate.markMutationFinished() }
            var history = LimitsHistory(url: fixture.source.limitsFile)
            history.append(
                session: LimitWindow(percent: 75, resetsAt: nil), week: nil,
                now: Date(timeIntervalSince1970: 1_777_249_000))
        }
        let saveTask = Task.detached {
            gate.markMutationStarted()
            defer { gate.markMutationFinished() }
            _ = try MachineUsageStore.save(
                document: Self.usage, machine: saved, slug: saved.name, host: saved.host,
                collectedAt: Date(), in: fixture.source.machinesDirectory)
        }
        let forgetTask = Task.detached {
            gate.markMutationStarted()
            defer { gate.markMutationFinished() }
            MachineUsageStore.forget(
                machineID: forgotten.id, in: fixture.source.machinesDirectory)
        }
        #expect(await gate.waitForMutationStarts(3))
        let mutationFinishedEarly = await gate.mutationFinishedEarly()
        #expect(!mutationFinishedEarly)
        held.release()
        let publication = try await publicationTask.value
        await appendTask.value
        _ = try await saveTask.value
        _ = await forgetTask.value

        #expect(publication.manifest.generation == identifier.uuidString.lowercased())
        #expect(try await store.current() == publication)
        if let limits = publication.manifest.files.first(where: {
            $0.path == "limits-history.jsonl"
        }) {
            let text = try String(
                contentsOf: publication.directory.appendingPathComponent(limits.path),
                encoding: .utf8)
            #expect(LimitsHistory.isValidDocument(text))
        }
        for file in publication.manifest.files where file.path.hasPrefix("machines/") {
            let data = try Data(contentsOf: publication.directory.appendingPathComponent(file.path))
            let object = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let block = try #require(object["machine"] as? [String: Any])
            let embedded = try #require(block["id"] as? String)
            let parsed = try #require(UUID(uuidString: embedded))
            let filename = String(
                file.path.dropFirst("machines/".count).dropLast(".json".count))
            #expect(
                parsed.uuidString.lowercased() == filename)
        }
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
        try FileManager.default.removeItem(at: fixture.snapshots)

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

    private static func runCrashDriver(
        dataDirectory: URL, root: URL, generation: UUID, point: String
    ) throws -> (reason: Process.TerminationReason, status: Int32) {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let process = Process()
        process.executableURL = package.appendingPathComponent(
            ".build/debug/UsageSnapshotCrashDriver")
        process.arguments = [dataDirectory.path, root.path, generation.uuidString, point]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return (process.terminationReason, process.terminationStatus)
    }
}
