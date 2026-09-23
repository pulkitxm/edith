import Foundation
import Testing

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
    }
}
