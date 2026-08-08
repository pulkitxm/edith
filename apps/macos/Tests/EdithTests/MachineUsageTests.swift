import Foundation
import Testing

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

    @Test func pruningDropsMachinesTheRegistryNoLongerHas() throws {
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

        MachineUsageStore.prune(keeping: [kept.id], in: dir)
        #expect(MachineUsageStore.storedIDs(in: dir) == [kept.id])
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
}

@Suite struct MachineUsageCollectorTests {
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
        #expect(MachineUsageCollector.probeCommand.contains("$HOME"))
        #expect(MachineUsageCollector.probeCommand.contains("uname -n"))
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

@Suite struct MachineUsageScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private let machine = Machine(id: UUID(), name: "tuf", host: "h")

    @Test func aMachineNobodyHasCollectedFromIsDue() {
        let due = UsageStore.machinesDue(
            [machine], force: false, now: now, collectedAt: { _ in nil })
        #expect(due.map(\.name) == ["tuf"])
    }

    @Test func aMachineCollectedJustNowWaits() {
        let due = UsageStore.machinesDue(
            [machine], force: false, now: now, collectedAt: { _ in now.addingTimeInterval(-60) })
        #expect(due.isEmpty)
    }

    @Test func aMachineGoesStaleAfterTheInterval() {
        let stale = now.addingTimeInterval(-UsageStore.machineInterval)
        let due = UsageStore.machinesDue(
            [machine], force: false, now: now, collectedAt: { _ in stale })
        #expect(due.map(\.name) == ["tuf"])
    }

    @Test func askingForItCollectsEvenFromAFreshMachine() {
        let due = UsageStore.machinesDue(
            [machine], force: true, now: now, collectedAt: { _ in now })
        #expect(due.map(\.name) == ["tuf"])
    }

    @Test func nothingIsDueWhenNoMachineTakesPart() {
        let due = UsageStore.machinesDue([], force: true, now: now, collectedAt: { _ in nil })
        #expect(due.isEmpty)
    }
}
