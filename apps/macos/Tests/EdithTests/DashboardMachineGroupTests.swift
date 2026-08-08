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
