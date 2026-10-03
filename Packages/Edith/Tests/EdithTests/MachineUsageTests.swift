import Darwin
import Foundation
import Testing

@testable import EdithCLI
@testable import EdithHelper
@testable import EdithKit

@Suite struct MachineUsageSlugTests {
    @Test func aNameBecomesOneLowercaseWordPerRun() {
        #expect(MachineUsageSlug.slug(for: "TUF Gaming") == "tuf-gaming")
        #expect(MachineUsageSlug.slug(for: "pi.local") == "pi-local")
        #expect(MachineUsageSlug.slug(for: "  edge  box  ") == "edge-box")
    }

    @Test func aNameWithNothingUsableStillGetsASlug() {
        #expect(MachineUsageSlug.slug(for: "") == "machine")
        #expect(MachineUsageSlug.slug(for: "···") == "machine")
        #expect(MachineUsageSlug.slug(for: "日本") == "machine")
    }

    @Test func aSlugNeverCarriesTheSeparatorSourceIdsUse() {
        #expect(!MachineUsageSlug.slug(for: "a:b").contains(":"))
    }

    @Test func twoMachinesNamedTheSameGetDifferentSlugs() {
        let first = Machine(id: UUID(), name: "box", host: "a")
        let second = Machine(id: UUID(), name: "BOX", host: "b")
        let third = Machine(id: UUID(), name: "other", host: "c")
        let slugs = MachineUsageSlug.slugs(for: [first, second, third])
        #expect(slugs[third.id] == "other")
        #expect(slugs[first.id] != slugs[second.id])
        #expect(slugs[first.id]?.hasPrefix("box-") == true)
        #expect(Set(slugs.values).count == 3)
    }

    @Test func slugsAreStableAcrossRuns() {
        let machines = [
            Machine(id: UUID(), name: "box", host: "a"),
            Machine(id: UUID(), name: "box", host: "b"),
        ]
        #expect(MachineUsageSlug.slugs(for: machines) == MachineUsageSlug.slugs(for: machines))
    }
}

@Suite struct MachineUsageSourceIdentityTests {
    private let machineID = "4303DCF1-52D8-4075-AE9B-C2FD86D3821A"

    @Test func aMachineRenameKeepsTheSameSourceIdentity() {
        let before = MachineUsageSourceIdentity.canonical(
            machineID: machineID, source: "tuf:codex")
        let after = MachineUsageSourceIdentity.canonical(
            machineID: machineID.lowercased(), source: "gaming:codex")
        #expect(before == "machine:\(machineID.lowercased()):codex")
        #expect(after == before)
    }

    @Test func anAlreadyCanonicalSourceStaysCanonical() {
        let source = "machine:\(machineID.lowercased()):cli"
        #expect(
            MachineUsageSourceIdentity.canonical(machineID: machineID, source: source) == source)
    }

    @Test func anAmbiguousSourceCannotGetAStableIdentity() {
        #expect(MachineUsageSourceIdentity.canonical(machineID: "", source: "tuf:codex") == nil)
        #expect(MachineUsageSourceIdentity.canonical(machineID: machineID, source: "") == nil)
    }
}

@Suite struct MachineUsageFreshnessTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    @Test func collectionStaysFreshThroughTheRefreshWindowAndTolerance() {
        let freshness = MachineUsageFreshness(
            collectedAt: now.addingTimeInterval(-(30 * 60 + 5 * 60)), now: now)
        #expect(!freshness.isStale)
        #expect(freshness.statusLabel == "collected 35m ago")
    }

    @Test func collectionBecomesStaleAfterTheTolerance() {
        let freshness = MachineUsageFreshness(
            collectedAt: now.addingTimeInterval(-(30 * 60 + 5 * 60 + 1)), now: now)
        #expect(freshness.isStale)
        #expect(freshness.statusLabel == "usage stale · collected 35m ago")
    }

    @Test func collectionAgeStaysCompactAndNeverGoesNegative() {
        #expect(
            MachineUsageFreshness(
                collectedAt: now.addingTimeInterval(30), now: now
            ).ageLabel == "just now")
        #expect(
            MachineUsageFreshness(
                collectedAt: now.addingTimeInterval(-(2 * 3600 + 7 * 60)), now: now
            ).ageLabel == "2h 7m ago")
        #expect(
            MachineUsageFreshness(
                collectedAt: now.addingTimeInterval(-(3 * 86400 + 4 * 3600)), now: now
            ).ageLabel == "3d 4h ago")
    }

}

@Suite struct MachineUsageSelectionTests {
    private func store() -> UserDefaults {
        let suite = UserDefaults(suiteName: "machine-usage-\(UUID().uuidString)")!
        suite.removePersistentDomain(forName: suite.description)
        return suite
    }

    @Test func nothingTakesPartUntilAMachineIsAdded() {
        let defaults = store()
        let id = UUID()
        #expect(!MachineUsageSelection.includes(id, defaults))
        MachineUsageSelection.include(id, defaults)
        #expect(MachineUsageSelection.includes(id, defaults))
        MachineUsageSelection.exclude(id, defaults)
        #expect(!MachineUsageSelection.includes(id, defaults))
    }

    @Test func theSelectionFiltersTheRegistryInOrder() {
        let defaults = store()
        let first = Machine(id: UUID(), name: "one", host: "a")
        let second = Machine(id: UUID(), name: "two", host: "b")
        MachineUsageSelection.include(second.id, defaults)
        let kept = MachineUsageSelection.included(in: [first, second], defaults)
        #expect(kept.map(\.name) == ["two"])
    }

    @Test func addingTheSameMachineTwiceKeepsOneEntry() {
        let defaults = store()
        let id = UUID()
        MachineUsageSelection.include(id, defaults)
        MachineUsageSelection.include(id, defaults)
        #expect(defaults.stringArray(forKey: MachineUsageSelection.key)?.count == 1)
    }
}

@Suite struct MachineUsageStoreTests {
    private func directory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("machine-usage-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let document = Data(
        """
        {"schemaVersion":6,"generatedAt":"2026-08-08T10:00:00Z","sources":["cli","codex"],
         "totals":{"cost":12.5,"tokens":400},
         "daily":[{"period":"2026-08-07","bySource":{}},{"period":"2026-08-08","bySource":{}}]}
        """.utf8)

    @Test func savingStampsTheMachineOntoTheDocumentItStores() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let machine = Machine(id: UUID(), name: "tuf", host: "10.0.0.5")
        let when = Date(timeIntervalSince1970: 1_780_000_000)
        let summary = try MachineUsageStore.save(
            document: document, machine: machine, slug: "tuf", host: "tuf-arch",
            collectedAt: when, in: dir)

        #expect(summary.machineID == machine.id)
        #expect(summary.slug == "tuf")
        #expect(summary.host == "tuf-arch")
        #expect(summary.sources == ["cli", "codex"])
        #expect(summary.days == 2)
        #expect(summary.cost == 12.5)
        #expect(summary.tokens == 400)
        #expect(summary.collectedAt == when)

        let stored = try JSONSerialization.jsonObject(
            with: Data(contentsOf: UsageCollector.machineFile(id: machine.id, in: dir)))
        let block = (stored as? [String: Any])?["machine"] as? [String: Any]
        #expect(block?["slug"] as? String == "tuf")
        #expect(block?["id"] as? String == machine.id.uuidString)
    }

    @Test func aDocumentWithoutDaysIsRefusedRatherThanStored() {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let machine = Machine(id: UUID(), name: "tuf", host: "h")
        #expect(throws: MachineUsageError.documentUnreadable("tuf")) {
            try MachineUsageStore.save(
                document: Data("{\"sources\":[]}".utf8), machine: machine, slug: "tuf",
                host: "h", collectedAt: Date(), in: dir)
        }
        #expect(MachineUsageStore.summaries(in: dir).isEmpty)
    }

    @Test func summariesReadEveryStoredMachineAndSkipRubbish() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = Machine(id: UUID(), name: "zeta", host: "a")
        let second = Machine(id: UUID(), name: "alpha", host: "b")
        try MachineUsageStore.save(
            document: document, machine: first, slug: "zeta", host: "a", collectedAt: Date(),
            in: dir)
        try MachineUsageStore.save(
            document: document, machine: second, slug: "alpha", host: "b", collectedAt: Date(),
            in: dir)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("junk.json"))

        #expect(MachineUsageStore.summaries(in: dir).map(\.name) == ["alpha", "zeta"])
    }

    @Test func storedHistorySurvivesRegistryChangesUntilExplicitlyForgotten() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let kept = Machine(id: UUID(), name: "kept", host: "a")
        let gone = Machine(id: UUID(), name: "gone", host: "b")
        try MachineUsageStore.save(
            document: document, machine: kept, slug: "kept", host: "a", collectedAt: Date(),
            in: dir)
        try MachineUsageStore.save(
            document: document, machine: gone, slug: "gone", host: "b", collectedAt: Date(),
            in: dir)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("junk.json"))

        #expect(MachineUsageStore.restamp([kept], in: dir).isEmpty)
        #expect(Set(MachineUsageStore.storedIDs(in: dir)) == [kept.id, gone.id])
        #expect(MachineUsageStore.forget(machineID: gone.id, in: dir))
        #expect(MachineUsageStore.storedIDs(in: dir) == [kept.id])
    }

    @Test func renamingAMachineRestampsWhatItAlreadyGave() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let machine = Machine(id: UUID(), name: "tuf", host: "h")
        try MachineUsageStore.save(
            document: document, machine: machine, slug: "tuf", host: "h", collectedAt: Date(),
            in: dir)

        var renamed = machine
        renamed.name = "workshop box"
        #expect(MachineUsageStore.restamp([renamed], in: dir) == [machine.id])

        let summary = try #require(MachineUsageStore.summary(machineID: machine.id, in: dir))
        #expect(summary.name == "workshop box")
        #expect(summary.slug == "workshop-box")
    }

    @Test func restampingIsANoOpWhenTheNameIsUnchanged() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let machine = Machine(id: UUID(), name: "tuf", host: "h")
        try MachineUsageStore.save(
            document: document, machine: machine, slug: "tuf", host: "h", collectedAt: Date(),
            in: dir)
        #expect(MachineUsageStore.restamp([machine], in: dir).isEmpty)
    }

    @Test func restampingLeavesMachinesItWasNotToldAboutAlone() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let machine = Machine(id: UUID(), name: "tuf", host: "h")
        try MachineUsageStore.save(
            document: document, machine: machine, slug: "tuf", host: "h", collectedAt: Date(),
            in: dir)
        #expect(MachineUsageStore.restamp([Machine(name: "other", host: "x")], in: dir).isEmpty)
        #expect(MachineUsageStore.summary(machineID: machine.id, in: dir)?.name == "tuf")
    }

    @Test func forgettingRemovesOnlyThatMachine() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let machine = Machine(id: UUID(), name: "tuf", host: "h")
        try MachineUsageStore.save(
            document: document, machine: machine, slug: "tuf", host: "h", collectedAt: Date(),
            in: dir)
        #expect(MachineUsageStore.forget(machineID: machine.id, in: dir))
        #expect(MachineUsageStore.summary(machineID: machine.id, in: dir) == nil)
        #expect(!MachineUsageStore.forget(machineID: machine.id, in: dir))
    }

    @Test func concurrentSavesAndForgetsLeaveCompleteMachineDocuments() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let machines = (0..<60).map {
            Machine(id: UUID(), name: "machine-\($0)", host: "host-\($0)")
        }
        let payload = document
        for machine in machines.prefix(20) {
            try MachineUsageStore.save(
                document: payload, machine: machine, slug: machine.name, host: machine.host,
                collectedAt: Date(), in: dir)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for machine in machines.prefix(20) {
                group.addTask {
                    guard MachineUsageStore.forget(machineID: machine.id, in: dir) else {
                        throw MachineUsageError.documentUnreadable(machine.name)
                    }
                }
            }
            for machine in machines.dropFirst(20) {
                group.addTask {
                    _ = try MachineUsageStore.save(
                        document: payload, machine: machine, slug: machine.name,
                        host: machine.host, collectedAt: Date(), in: dir)
                }
            }
            try await group.waitForAll()
        }

        #expect(Set(MachineUsageStore.storedIDs(in: dir)) == Set(machines.dropFirst(20).map(\.id)))
        #expect(MachineUsageStore.summaries(in: dir).count == 40)
    }

    @Test func restampRejectsSymlinkedMachineDocuments() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let machine = Machine(id: UUID(), name: "renamed", host: "host")
        let target = dir.appendingPathComponent("outside.json")
        let file = UsageCollector.machineFile(id: machine.id, in: dir)
        let original = Data("preserve".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)

        #expect(MachineUsageStore.restamp([machine], in: dir).isEmpty)
        #expect(try Data(contentsOf: target) == original)
    }

    @Test func restampRejectsFifoMachineDocumentsWithoutBlocking() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let machine = Machine(id: UUID(), name: "renamed", host: "host")
        let file = UsageCollector.machineFile(id: machine.id, in: dir)
        #expect(mkfifo(file.path, mode_t(S_IRUSR | S_IWUSR)) == 0)

        #expect(MachineUsageStore.restamp([machine], in: dir).isEmpty)
        var metadata = stat()
        #expect(lstat(file.path, &metadata) == 0)
        #expect(metadata.st_mode & S_IFMT == S_IFIFO)
    }

    @Test func everyStoredFleetMutationAdvancesTheRefreshGeneration() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let machine = Machine(id: UUID(), name: "tuf", host: "h")
        #expect(try MachineUsageStore.generation(in: dir) == nil)

        try MachineUsageStore.save(
            document: document, machine: machine, slug: "tuf", host: "h", collectedAt: Date(),
            in: dir)
        let saved = try #require(try MachineUsageStore.generation(in: dir))

        var renamed = machine
        renamed.name = "renamed"
        #expect(MachineUsageStore.restamp([renamed], in: dir) == [machine.id])
        let restamped = try #require(try MachineUsageStore.generation(in: dir))
        #expect(restamped != saved)

        #expect(MachineUsageStore.forget(machineID: machine.id, in: dir))
        let forgotten = try #require(try MachineUsageStore.generation(in: dir))
        #expect(forgotten != restamped)
    }
}

@Suite struct MachineUsageCollectorTests {
    private func decodedPowerShell(_ command: String) -> String {
        guard let encoded = command.split(separator: " ").last,
            let data = Data(base64Encoded: String(encoded)),
            let script = String(data: data, encoding: .utf16LittleEndian)
        else { return "" }
        return script
    }

    @Test func theRemoteRunWritesUnderTheMachinesOwnHome() {
        #expect(
            MachineUsageCollector.runCommand(home: "/home/pi")
                == "bash -s -- /home/pi/.cache/edith/usage")
        #expect(
            MachineUsageCollector.documentPath(home: "/home/pi")
                == "/home/pi/.cache/edith/usage/usage.json")
    }

    @Test func aHomeWithSpacesIsStillOneArgument() {
        let command = MachineUsageCollector.runCommand(home: "/Users/some one")
        #expect(command == "bash -s -- '/Users/some one/.cache/edith/usage'")
    }

    @Test func theProbeAsksForTheHomeAndTheHostName() {
        let command = MachineUsageCollector.probeCommand(platform: .linux)
        #expect(command.contains("$HOME"))
        #expect(command.contains("uname -n"))
    }

    @Test func windowsUsesItsNativeHomeAndGitBashCollector() {
        let probe = decodedPowerShell(MachineUsageCollector.probeCommand(platform: .windows))
        let command = decodedPowerShell(
            MachineUsageCollector.runCommand(
                home: "C:\\Users\\kpulk", platform: .windows))
        #expect(probe.contains("USERPROFILE"))
        #expect(command.contains("Git/bin/bash.exe"))
        #expect(command.contains("bash -s --"))
        #expect(
            MachineUsageCollector.documentPath(
                home: "C:\\Users\\kpulk", platform: .windows)
                == "C:\\Users\\kpulk\\.cache\\edith\\usage\\usage.json")
    }

    @Test func windowsProbeRemovesCarriageReturnsFromItsPaths() {
        let values = MachineUsageCollector.probeValues("C:\\Users\\kpulk\r\nPULKIT-TUF\r\n")
        #expect(values.home == "C:\\Users\\kpulk")
        #expect(values.host == "PULKIT-TUF")
    }

    @Test func theReportedFailureIsTheLastThingTheCollectorSaid() {
        let log = "  ▸ cli 3 days\n  ✖ jq is required and could not be installed\n\n"
        #expect(
            MachineUsageCollector.lastLine(of: log)
                == "✖ jq is required and could not be installed")
        #expect(MachineUsageCollector.lastLine(of: "   \n\n") == "")
    }

    @Test func theCollectorScriptShipsWithThisBuild() {
        #expect(UsageCollector.script() != nil)
    }
}

@Suite struct MachineUsageRoundTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private let machine = Machine(id: UUID(), name: "tuf", host: "h")

    @Test func aMachineNobodyHasCollectedFromIsDue() {
        let due = MachineUsageRound.due(
            [machine], force: false, now: now, collectedAt: { _ in nil })
        #expect(due.map(\.name) == ["tuf"])
    }

    @Test func aMachineCollectedJustNowWaits() {
        let due = MachineUsageRound.due(
            [machine], force: false, now: now, collectedAt: { _ in now.addingTimeInterval(-60) })
        #expect(due.isEmpty)
    }

    @Test func aMachineGoesStaleAfterTheInterval() {
        let stale = now.addingTimeInterval(-MachineUsageRound.interval)
        let due = MachineUsageRound.due(
            [machine], force: false, now: now, collectedAt: { _ in stale })
        #expect(due.map(\.name) == ["tuf"])
    }

    @Test func askingForItCollectsEvenFromAFreshMachine() {
        let due = MachineUsageRound.due(
            [machine], force: true, now: now, collectedAt: { _ in now })
        #expect(due.map(\.name) == ["tuf"])
    }

    @Test func nothingIsDueWhenNoMachineTakesPart() {
        let due = MachineUsageRound.due([], force: true, now: now, collectedAt: { _ in nil })
        #expect(due.isEmpty)
    }

    @Test func aRoundWithNothingToDoNeverTakesTheLock() async {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("machine-round-\(UUID().uuidString)")
        let result = await MachineUsageRound.collect([], dataDir: dir)
        #expect(result.collected.isEmpty)
        #expect(!result.skippedBecauseBusy)
        let lock = MachineUsageRound.lockURL(dataDir: dir)
        #expect(!FileManager.default.fileExists(atPath: lock.path))
    }

    @Test func aSecondRoundStandsAsideWhileOneIsRunning() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("machine-round-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let held = try #require(
            UsageRefreshLock.acquire(at: MachineUsageRound.lockURL(dataDir: dir)))
        defer { held.release() }

        let result = await MachineUsageRound.collect(
            [Machine(name: "unreachable", host: "127.0.0.1")], dataDir: dir)
        #expect(result.skippedBecauseBusy)
        #expect(result.collected.isEmpty)
    }

    @Test func aCollectedMachineIsDescribedByDaysAndAgents() {
        let summary = MachineUsageSummary(
            machineID: UUID(), name: "tuf", slug: "tuf", host: "h", collectedAt: now,
            sources: ["cli"], days: 5, cost: 1, tokens: 2)
        #expect(MachineUsageRound.describe(summary) == "5 days · 1 agent")
    }

    private func roundDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("machine-round-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func collection(for input: MachineUsageAttempt) -> MachineUsageCollection {
        MachineUsageCollection(
            summary: MachineUsageSummary(
                machineID: input.machine.id, name: input.machine.name, slug: input.slug,
                host: input.machine.host, collectedAt: Date(), sources: ["cli"], days: 1,
                cost: 1, tokens: 1),
            log: "")
    }

    @Test func everyMachineIsCollectedAtTheSameTime() async throws {
        let dir = try roundDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let machines = ["lan", "cloud", "edge"].map { Machine(name: $0, host: "h-\($0)") }
        let events = LockedEvents()
        let clock = ContinuousClock()
        let started = clock.now
        let result = await MachineUsageRound.collect(
            machines, registry: machines, dataDir: dir, onEvent: events.append,
            attempt: { input in
                let pause = input.machine.name == "lan" ? 0.2 : 0.8
                try await Task.sleep(for: .seconds(pause))
                return Self.collection(for: input)
            })
        #expect(clock.now - started < .seconds(1.6))
        #expect(result.collected.map(\.name) == ["lan", "cloud", "edge"])
        #expect(result.failures.isEmpty)
        let phases = events.all.compactMap { event -> String? in
            guard case let .phase(name, _, _) = event else { return nil }
            return name
        }
        #expect(phases.first == "lan")
        #expect(Set(phases) == ["lan", "cloud", "edge"])
    }

    @Test func aLargeFleetIsCollectedInBoundedWaves() async throws {
        let dir = try roundDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let machines = (0..<11).map { Machine(name: "box-\($0)", host: "h\($0)") }
        let inFlight = LockedCounter()
        let peak = LockedCounter()
        let result = await MachineUsageRound.collect(
            machines, registry: machines, dataDir: dir,
            attempt: { input in
                peak.raise(to: inFlight.increment())
                try await Task.sleep(for: .milliseconds(50))
                inFlight.decrement()
                return Self.collection(for: input)
            })
        #expect(result.collected.map(\.name) == machines.map(\.name))
        #expect(peak.value == MachineUsageRound.maximumConcurrentMachines)
    }

    @Test func theRoundDeadlineCoversEveryWave() {
        let one = MachineUsageRound.deadline(timeout: 900)
        #expect(one == 1_020)
        #expect(MachineUsageRound.roundDeadline(machines: 0, timeout: 900) == one)
        #expect(MachineUsageRound.roundDeadline(machines: 8, timeout: 900) == one)
        #expect(MachineUsageRound.roundDeadline(machines: 9, timeout: 900) == one * 2)
    }

    @Test func anUnreachableMachineDoesNotHoldUpTheOthers() async throws {
        let dir = try roundDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let machines = [Machine(name: "offline", host: "a"), Machine(name: "online", host: "b")]
        let events = LockedEvents()
        let result = await MachineUsageRound.collect(
            machines, registry: machines, dataDir: dir, onEvent: events.append,
            attempt: { input in
                guard input.machine.name == "online" else {
                    throw SSHConnectionError.connectFailed(
                        SSHConnectFailure(message: "Connection timed out.", isRecoverable: true))
                }
                return Self.collection(for: input)
            })
        #expect(result.collected.map(\.name) == ["online"])
        #expect(result.failures.map(\.machine) == ["offline"])
        #expect(result.failures.first?.reason == "Connection timed out.")
        #expect(events.all.contains(.note("offline: Connection timed out.")))
    }

    @Test func aMachineThatHangsIsCutOffAtItsDeadline() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: MachineUsageError.timedOut("stuck", seconds: 1)) {
            try await MachineUsageRound.withinDeadline(0.2, machine: "stuck") {
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        }
        #expect(clock.now - started < .seconds(5))
    }

    @Test func aMachineThatAnswersInTimeKeepsItsResult() async throws {
        let value = try await MachineUsageRound.withinDeadline(5, machine: "quick") { 7 }
        #expect(value == 7)
    }

    @Test func aDroppedConnectionIsRetriedOnce() async throws {
        let attempts = LockedCounter()
        try await MachineUsageRound.retryingOnceWhenRecoverable(pause: .zero) {
            if attempts.increment() == 1 {
                throw SSHConnectionError.connectFailed(
                    SSHConnectFailure(message: "Connection timed out.", isRecoverable: true))
            }
        }
        #expect(attempts.value == 2)
    }

    @Test func aRejectedLoginIsNotRetried() async {
        let attempts = LockedCounter()
        await #expect(throws: SSHConnectionError.self) {
            try await MachineUsageRound.retryingOnceWhenRecoverable(pause: .zero) {
                attempts.increment()
                throw SSHConnectionError.connectFailed(
                    SSHConnectFailure(message: "Authentication failed.", isRecoverable: false))
            }
        }
        #expect(attempts.value == 1)
    }
}

private final class LockedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [UsageRefreshEvent] = []

    var all: [UsageRefreshEvent] { lock.withLock { events } }

    @Sendable func append(_ event: UsageRefreshEvent) {
        lock.withLock { events.append(event) }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }

    func decrement() {
        lock.withLock { count -= 1 }
    }

    func raise(to candidate: Int) {
        lock.withLock { count = max(count, candidate) }
    }
}

@Suite struct MachineReachTests {
    @Test(arguments: [
        "10.77.0.2", "192.168.1.20", "172.20.4.1", "169.254.3.3", "127.0.0.1", "::1",
        "fe80::1%en0", "fd7a:115c:a1e0::1", "tuf.local", "localhost",
    ])
    func machinesOnThisNetworkGetAShortConnectTimeout(host: String) {
        #expect(MachineReach(host: host) == .local)
        #expect(MachineReach(host: host).connectTimeout == 3)
    }

    @Test(arguments: [
        "34.47.145.94", "172.32.0.1", "100.101.102.103", "2001:4860:4860::8888",
        "box.example.com", "noveum-gcp-prsnl",
    ])
    func machinesElsewhereGetMoreTimeToAnswer(host: String) {
        #expect(MachineReach(host: host) == .remote)
        #expect(MachineReach(host: host).connectTimeout == 6)
    }

    @Test func bothAreQuickerThanTheInteractiveDefault() {
        #expect(MachineReach.remote.connectTimeout < SSHConnection.defaultConnectTimeout)
    }
}

@Suite struct UsageMachineFilterTests {
    private let tufID = "4303DCF1-52D8-4075-AE9B-C2FD86D3821A"

    private func document() throws -> UsageDocument {
        let json = """
            {
              "sources": ["cli", "codex", "tuf:cli", "tuf:codex"],
              "sourceMeta": {
                "cli": {"label": "Claude Code"},
                "codex": {"label": "Codex"},
                "tuf:cli": {
                  "label": "Claude Code · Asus TUF 7", "machine": "Asus TUF 7",
                  "machineID": "\(tufID)"
                },
                "tuf:codex": {
                  "label": "Codex · Asus TUF 7", "machine": "Asus TUF 7",
                  "machineID": "\(tufID)"
                }
              },
              "daily": []
            }
            """
        return try JSONDecoder().decode(UsageDocument.self, from: Data(json.utf8))
    }

    @Test func aMachineNameSelectsEveryAgentItRan() throws {
        let sources = UsageMachineFilter.sources(matching: "Asus TUF 7", in: try document())
        #expect(sources == ["tuf:cli", "tuf:codex"])
    }

    @Test func theNameIsMatchedWithoutCaringAboutCase() throws {
        #expect(
            UsageMachineFilter.sources(matching: "asus tuf 7", in: try document())
                == ["tuf:cli", "tuf:codex"])
    }

    @Test func aRenamedMachineIsStillFoundByItsID() throws {
        let id = UUID(uuidString: tufID)
        let sources = UsageMachineFilter.sources(
            matching: "workshop box", in: try document(), machineID: id)
        #expect(sources == ["tuf:cli", "tuf:codex"])
    }

    @Test func localMeansTheSourcesNoMachineClaimed() throws {
        let doc = try document()
        #expect(UsageMachineFilter.sources(matching: "local", in: doc) == ["cli", "codex"])
        #expect(UsageMachineFilter.sources(matching: "This Mac", in: doc) == ["cli", "codex"])
    }

    @Test func aMachineThatGaveNothingMatchesNothing() throws {
        #expect(UsageMachineFilter.sources(matching: "pi", in: try document()).isEmpty)
    }
}

@Suite struct MachineCollectorSpeechTests {
    @Test func aWireLineIsReadBackAsSomethingASentenceCanHold() {
        #expect(
            MachineUsageCollector.lastLine(of: "note\tdiscovering sources\n")
                == "discovering sources")
        #expect(
            MachineUsageCollector.lastLine(of: "phase\tcli\t28 days\t1.35\n") == "cli: 28 days")
        #expect(
            MachineUsageCollector.lastLine(of: "error\tjq is missing\n") == "jq is missing")
    }

    @Test func aPlainLineIsLeftAlone() {
        #expect(MachineUsageCollector.lastLine(of: "  ✖ it broke\n") == "✖ it broke")
        #expect(MachineUsageCollector.lastLine(of: "") == "")
    }

    @Test func theTransportFailureIsTheOneSSHUses() {
        #expect(MachineUsageCollector.transportFailure == 255)
    }
}
