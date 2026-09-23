import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct MachineUsageBindingsTests {
    private func history(_ machine: Machine, connectionID: UUID? = nil) -> MachineUsageSummary {
        MachineUsageSummary(
            machineID: machine.id, name: machine.name, slug: machine.name,
            host: "fixture-host", collectedAt: .distantPast, sources: ["cli"],
            days: 1, cost: 2, tokens: 100, connectionID: connectionID)
    }

    @Test func readdedMachineKeepsHistoryAndCollectionChoice() throws {
        let old = Machine(name: "fixture", host: "192.0.2.1")
        let current = Machine(name: "fixture", host: "192.0.2.2")
        let bindings = MachineUsageBindings(machines: [current], summaries: [history(old)])
        #expect(bindings.identity(for: current.id) == old.id)
        #expect(bindings.included([current], selected: [old.id]) == [current])
        #expect(bindings.included([current], selected: []).isEmpty)
        try bindings.validateHost("fixture-host", for: current)
        #expect(throws: MachineUsageError.historyHostMismatch(current.name)) {
            try bindings.validateHost("different-host", for: current)
        }
    }

    @Test func registeredAndAmbiguousHistoriesAreNeverAdopted() {
        let old = Machine(name: "fixture", host: "192.0.2.1")
        let current = Machine(name: "fixture", host: "192.0.2.2")
        let other = Machine(name: "fixture", host: "192.0.2.3")
        for bindings in [
            MachineUsageBindings(machines: [old, current], summaries: [history(old)]),
            MachineUsageBindings(machines: [current], summaries: [history(old), history(other)]),
            MachineUsageBindings(machines: [current, other], summaries: [history(old)]),
        ] {
            #expect(bindings.identity(for: current.id) == current.id)
        }
    }

    @Test func savedConnectionSurvivesRenameAndTakesPrecedenceOverName() {
        let old = Machine(name: "fixture", host: "192.0.2.1")
        let current = Machine(name: "renamed", host: "192.0.2.2")
        let other = Machine(name: "renamed", host: "192.0.2.3")
        let bindings = MachineUsageBindings(
            machines: [current],
            summaries: [history(old, connectionID: current.id), history(other)])
        #expect(bindings.identity(for: current.id) == old.id)
    }

    @Test func savingReconnectedUsageKeepsOneHistoryAndRecordsConnection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = Machine(name: "fixture", host: "192.0.2.1")
        let current = Machine(name: "fixture", host: "192.0.2.2")
        let document = Data(#"{"daily":[{"period":"2026-09-01"}],"sources":["cli"]}"#.utf8)
        _ = try MachineUsageStore.save(
            document: document, machine: old, slug: "fixture", host: "fixture-host",
            collectedAt: .distantPast, in: directory)
        _ = try MachineUsageStore.save(
            document: document, machine: current, slug: "fixture", host: "fixture-host",
            collectedAt: Date(), in: directory, identity: old.id)
        let stored = MachineUsageStore.summaries(in: directory)
        #expect(stored.count == 1)
        #expect(stored.first?.machineID == old.id)
        #expect(stored.first?.connectionID == current.id)
        #expect(stored.first?.collectedAt != .distantPast)
        var renamed = current
        renamed.name = "fixture-renamed"
        #expect(MachineUsageStore.restamp([renamed], in: directory) == [old.id])
        let bindings = MachineUsageBindings(machines: [renamed], directory: directory)
        #expect(bindings.identity(for: renamed.id) == old.id)
        #expect(bindings.summaries[renamed.id]?.name == renamed.name)
        let due = MachineUsageRound.due(
            [renamed], force: false, collectedAt: { bindings.summaries[$0]?.collectedAt })
        #expect(due.isEmpty)
    }
    @Test func cliUsesReaddedConnectionForSelectionAndForgetting() async throws {
        try await CLIProbe.inWorld { world in
            let old = Machine(name: "fixture", host: "192.0.2.1")
            let current = Machine(name: "fixture", host: "192.0.2.2")
            let document = Data(#"{"daily":[{"period":"2026-09-01"}],"sources":["cli"]}"#.utf8)
            _ = try MachineUsageStore.save(
                document: document, machine: old, slug: "fixture", host: "fixture-host",
                collectedAt: .distantPast)
            world.shared.set([old.id.uuidString], forKey: MachineUsageSelection.key)
            MachineRegistry.add(current)

            #expect(MachineUsageSelection.included(in: [current], world.shared) == [current])
            let listed = await CLIProbe.capture(["usage", "machines", "ls", "--json"])
            #expect(listed.code == 0)
            #expect(listed.stdout.contains("fixture-host"))
            #expect(listed.stdout.contains("true"))

            let disabled = await CLIProbe.capture([
                "usage", "machines", "disable", "fixture", "--json",
            ])
            #expect(disabled.code == 0)
            #expect(MachineUsageSelection.included(in: [current], world.shared).isEmpty)
            let enabled = await CLIProbe.capture([
                "usage", "machines", "enable", "fixture", "--json",
            ])
            #expect(enabled.code == 0)
            #expect(MachineUsageSelection.machineIDs(world.shared) == [old.id])

            #expect(
                UsageCollectionOperationExecution.forgetMachine(
                    machineID: current.id, store: world.shared, afterDrop: {}))
            #expect(MachineUsageStore.summaries().isEmpty)
            #expect(MachineUsageSelection.machineIDs(world.shared).isEmpty)
        }
    }

    @Test func twoRegisteredOwnersCannotShareOneHistory() {
        let old = Machine(name: "old", host: "192.0.2.1")
        let current = Machine(name: "new", host: "192.0.2.2")
        let bindings = MachineUsageBindings(
            machines: [old, current], summaries: [history(old, connectionID: current.id)])
        #expect(bindings.summaries.isEmpty)
    }

}
