import EdithKit
import Foundation
import Testing

@testable import Edith

@MainActor
@Suite struct DashboardMachineGroupTests {
    private let tufID = "4303DCF1-52D8-4075-AE9B-C2FD86D3821A"

    private func meta(_ pairs: [(String, String?, String?)]) -> [String: DashUsage.Meta] {
        var out: [String: DashUsage.Meta] = [:]
        for (id, machine, machineID) in pairs {
            let json = """
                {"label": "\(id)", "tool": "\(id)"
                \(machine.map { ", \"machine\": \"\($0)\"" } ?? "")
                \(machineID.map { ", \"machineID\": \"\($0)\"" } ?? "")
                }
                """
            out[id] = try! JSONDecoder().decode(DashUsage.Meta.self, from: Data(json.utf8))
        }
        return out
    }

    @Test func localSourcesLeadAndKeepTheirOwnGroup() {
        let groups = DashboardModel.groupByMachine(
            ["cli", "codex", "tuf:cli"],
            meta: meta([("cli", nil, nil), ("codex", nil, nil), ("tuf:cli", "tuf", tufID)]),
            naming: [:])
        #expect(groups.map(\.name) == ["This Mac", "tuf"])
        #expect(groups[0].sourceIDs == ["cli", "codex"])
        #expect(groups[0].isLocal)
        #expect(groups[1].sourceIDs == ["tuf:cli"])
    }

    @Test func theAgentsNamedInARowAreExactlyTheOnesItCounts() {
        let groups = DashboardModel.groupByMachine(
            ["cli", "codex", "cowork", "tuf:cli"],
            meta: meta([
                ("cli", nil, nil), ("codex", nil, nil), ("cowork", nil, nil),
                ("tuf:cli", "tuf", tufID),
            ]),
            naming: [:])
        for group in groups {
            #expect(
                group.agentNames.count == group.sourceIDs.count,
                "\(group.name) counts \(group.sourceIDs.count) and names \(group.agentNames)")
        }
        #expect(groups[0].agentSummary == "cli, codex, cowork")
        #expect(groups[1].agentSummary == "tuf:cli")
    }

    @Test func aLocalAgentIsNamedByItsOwnLabelNotTheToolItRuns() {
        let cowork = try! JSONDecoder().decode(
            DashUsage.Meta.self,
            from: Data(#"{"label": "Cowork", "tool": "Claude Code"}"#.utf8))
        #expect(DashboardModel.agentName(cowork, id: "cowork", local: true) == "Cowork")
    }

    @Test func aCollectedAgentDropsTheMachineSuffixItsLabelCarries() {
        let remote = try! JSONDecoder().decode(
            DashUsage.Meta.self,
            from: Data(
                #"{"label": "Claude Code · Asus TUF 7", "tool": "Claude Code"}"#.utf8))
        #expect(DashboardModel.agentName(remote, id: "tuf:cli", local: false) == "Claude Code")
    }

    @Test func aRenamedMachineShowsItsCurrentNameNotTheCollectedOne() {
        let groups = DashboardModel.groupByMachine(
            ["cli", "tuf:cli"],
            meta: meta([("cli", nil, nil), ("tuf:cli", "Asus TUF 7", tufID)]),
            naming: [tufID.lowercased(): "workshop box"])
        #expect(groups.map(\.name) == ["This Mac", "workshop box"])
    }

    @Test func aMachineNoLongerInTheRegistryKeepsTheNameItWasCollectedUnder() {
        let groups = DashboardModel.groupByMachine(
            ["cli", "tuf:cli"],
            meta: meta([("cli", nil, nil), ("tuf:cli", "Asus TUF 7", tufID)]),
            naming: [:])
        #expect(groups.map(\.name) == ["This Mac", "Asus TUF 7"])
    }

    @Test func sourcesFromOneMachineGatherEvenWithoutAnID() {
        let groups = DashboardModel.groupByMachine(
            ["cli", "pi:cli", "pi:codex"],
            meta: meta([("cli", nil, nil), ("pi:cli", "pi", nil), ("pi:codex", "pi", nil)]),
            naming: [:])
        #expect(groups.count == 2)
        #expect(groups[1].sourceIDs == ["pi:cli", "pi:codex"])
    }

    @Test func aMacWithNoMachinesHasNothingToGroup() {
        let groups = DashboardModel.groupByMachine(
            ["cli", "codex"], meta: meta([("cli", nil, nil), ("codex", nil, nil)]), naming: [:])
        #expect(groups.isEmpty)
    }

    @Test func tickingAMachineTicksItsSourcesAndOnlyThose() throws {
        let name = "DashboardMachineGroupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = DashboardModel(preferences: defaults)
        model.ingest(try usage())

        let tuf = try #require(model.machineGroups.first { !$0.isLocal })
        let local = try #require(model.machineGroups.first { $0.isLocal })
        #expect(model.machineIsShown(tuf))

        model.showMachine(tuf, false)
        #expect(!model.machineIsShown(tuf))
        #expect(model.machineIsShown(local))
        #expect(model.selectedSources == ["cli"])

        model.showMachine(tuf, true)
        #expect(model.selectedSources == ["cli", "tuf:cli"])
    }

    @Test func hidingTheLastMachineIsRefusedSoTheChartsAreNeverEmpty() throws {
        let name = "DashboardMachineGroupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = DashboardModel(preferences: defaults)
        model.ingest(try usage())

        for group in model.machineGroups { model.showMachine(group, false) }
        #expect(!model.selectedSources.isEmpty)
    }

    @Test func showingOnlyOneMachineDropsEverythingElse() throws {
        let name = "DashboardMachineGroupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = DashboardModel(preferences: defaults)
        model.ingest(try usage())

        let tuf = try #require(model.machineGroups.first { !$0.isLocal })
        model.showOnlyMachine(tuf)
        #expect(model.selectedSources == ["tuf:cli"])
        #expect(!model.machineIsShown(try #require(model.machineGroups.first)))
    }

    @Test func foldedCollectionTimeDrivesRemoteFreshness() throws {
        let name = "DashboardMachineGroupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = DashboardModel(preferences: defaults)
        model.ingest(try usage())

        let tuf = try #require(model.machineGroups.first { !$0.isLocal })
        let now = try #require(EdithDate.parseISO("2026-08-11T19:00:01Z"))
        let freshness = try #require(model.machineFreshness(tuf, now: now))
        #expect(freshness.isStale)
        #expect(freshness.statusLabel == "stale · collected 40m ago")
    }

    private func usage() throws -> DashUsage {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let period = formatter.string(from: Date())
        let json = """
            {
              "schemaVersion": 6,
              "sources": ["cli", "tuf:cli"],
              "defaultSources": ["cli", "tuf:cli"],
              "sourceMeta": {
                "cli": {"label": "Claude Code"},
                "tuf:cli": {
                  "label": "Claude Code · tuf", "machine": "tuf", "machineID": "\(tufID)"
                }
              },
              "machines": [{
                "id": "\(tufID)", "collectedAt": "2026-08-11T18:20:00Z"
              }],
              "daily": [{
                "period": "\(period)",
                "bySource": {
                  "cli": [{
                    "modelName": "claude", "inputTokens": 10, "outputTokens": 0,
                    "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": 1
                  }],
                  "tuf:cli": [{
                    "modelName": "claude", "inputTokens": 20, "outputTokens": 0,
                    "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": 2
                  }]
                }
              }]
            }
            """
        return try JSONDecoder().decode(DashUsage.self, from: Data(json.utf8))
    }
}

@Suite struct MachineUsageRowsTests {
    private func summary(_ name: String) -> MachineUsageSummary {
        MachineUsageSummary(
            machineID: UUID(), name: name, slug: name, host: "h", collectedAt: Date(),
            sources: ["cli"], days: 3, cost: 1, tokens: 2)
    }

    @Test func aRunningRoundSpeaksItsPhasesAndNotes() {
        #expect(
            MachineUsageRows.spoken(.phase(name: "tuf", detail: "5 days · 1 agent", seconds: 2))
                == "tuf: 5 days · 1 agent")
        #expect(MachineUsageRows.spoken(.note("tuf: timed out")) == "tuf: timed out")
        #expect(MachineUsageRows.spoken(.finished(seconds: 1)) == nil)
    }

    @Test func theOutcomeSaysWhatActuallyHappened() {
        #expect(
            MachineUsageRows.outcome(MachineUsageRoundResult(collected: [summary("tuf")]))
                == "1 machine collected")
        #expect(
            MachineUsageRows.outcome(
                MachineUsageRoundResult(collected: [summary("a"), summary("b")]))
                == "2 machines collected")
        #expect(MachineUsageRows.outcome(MachineUsageRoundResult()) == "nothing to collect")
    }

    @Test func aFailedRoundNamesTheMachineAndTheReason() {
        let failed = MachineUsageRoundResult(failures: [(machine: "tuf", reason: "down")])
        #expect(MachineUsageRows.outcome(failed) == "tuf: down")
    }

    @Test func aPartlyFailedRoundCountsBothSides() {
        let mixed = MachineUsageRoundResult(
            collected: [summary("tuf")], failures: [(machine: "pi", reason: "down")])
        #expect(MachineUsageRows.outcome(mixed) == "1 machine collected, 1 failed")
    }

    @Test func aRoundThatStoodAsideSaysSoRatherThanClaimingNothingToDo() {
        #expect(
            MachineUsageRows.outcome(MachineUsageRoundResult(skippedBecauseBusy: true))
                == "another collection is already running")
    }
}
