import Foundation
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
@Suite struct HerdrNewAgentPopupModelTests {
    @Test func matchingKindsFiltersCaseInsensitively() {
        #expect(HerdrNewAgentPopupModel.matchingKinds("") == HerdrKind.filterLabels)
        #expect(HerdrNewAgentPopupModel.matchingKinds("codex") == ["Codex"])
        #expect(HerdrNewAgentPopupModel.matchingKinds("CLAUDE") == ["Claude Code"])
        #expect(HerdrNewAgentPopupModel.matchingKinds("nonexistent").isEmpty)
    }

    @Test func matchingMachinesFiltersByName() {
        let hosts = [
            HerdrHostSnapshot.local(herdrPresent: true),
            HerdrHostSnapshot(
                id: "remote-1", name: "tuf-wired", isLocal: false, herdrPresent: true,
                reachable: true),
        ]
        #expect(HerdrNewAgentPopupModel.matchingMachines("", in: hosts).count == 2)
        #expect(
            HerdrNewAgentPopupModel.matchingMachines("tuf", in: hosts).map(\.id) == ["remote-1"])
        #expect(HerdrNewAgentPopupModel.matchingMachines("this", in: hosts).map(\.id) == ["local"])
    }

    @Test func matchingSpacesFiltersByLabel() {
        let workspaces = [
            HerdrWorkspaceSummary(id: "w1", label: "edith-worktrees", tabCount: 3, paneCount: 3),
            HerdrWorkspaceSummary(id: "w2", label: "quinjet", tabCount: 1, paneCount: 1),
        ]
        #expect(HerdrNewAgentPopupModel.matchingSpaces("", in: workspaces).count == 2)
        #expect(
            HerdrNewAgentPopupModel.matchingSpaces("edith", in: workspaces).map(\.id) == ["w1"])
    }

    @Test func matchingSpaceRequiresAnExactCaseInsensitiveLabelMatch() {
        let workspaces = [
            HerdrWorkspaceSummary(id: "w1", label: "Edith Worktrees", tabCount: 1, paneCount: 1)
        ]
        #expect(
            HerdrNewAgentPopupModel.matchingSpace(named: "edith worktrees", in: workspaces)?.id
                == "w1")
        #expect(HerdrNewAgentPopupModel.matchingSpace(named: "edith", in: workspaces) == nil)
        #expect(HerdrNewAgentPopupModel.matchingSpace(named: "  ", in: workspaces) == nil)
    }

    @Test func selectKindAdvancesToMachineStep() {
        let model = HerdrNewAgentPopupModel()
        model.selectKind("Claude Code")
        #expect(model.selectedKind == "Claude Code")
        #expect(model.step == .machine)
    }

    @Test func selectMachineIgnoresUnavailableHosts() {
        let model = HerdrNewAgentPopupModel()
        model.step = .machine
        let unreachable = HerdrHostSnapshot(
            id: "remote-1", name: "tuf-wired", isLocal: false, herdrPresent: true, reachable: false)
        model.selectMachine(unreachable)
        #expect(model.selectedHost == nil)
        #expect(model.step == .machine)

        let available = HerdrHostSnapshot.local(herdrPresent: true)
        model.selectMachine(available)
        #expect(model.selectedHost?.id == "local")
        #expect(model.step == .space)
    }

    @Test func backWalksStepsInReverseAndStopsAtKind() {
        let model = HerdrNewAgentPopupModel()
        model.step = .space
        #expect(model.back())
        #expect(model.step == .machine)
        #expect(model.back())
        #expect(model.step == .kind)
        #expect(model.back() == false)
        #expect(model.step == .kind)
    }

    @Test(arguments: [false, true])
    func spaceLaunchOnlyAsksForKindAndUsesTheSelectedMachine(remote: Bool) async throws {
        let machine = Machine(name: "Demo server", host: "demo.invalid")
        let host =
            remote
            ? HerdrHostSnapshot(
                id: machine.id.uuidString, name: machine.name, isLocal: false,
                herdrPresent: true, reachable: true)
            : .local(herdrPresent: true)
        let agent = spaceAgent(host)
        let space = try #require(HerdrAgentSpace.group([agent]).first)
        let workspace = HerdrWorkspaceSummary(id: "w4", label: "demo", tabCount: 1, paneCount: 1)
        let store = HerdrStore(
            newAgentLauncher: { kind, destination, existingSpace, newLabel in
                #expect(kind == "OpenCode")
                #expect(destination?.id == (remote ? machine.id : nil))
                #expect(existingSpace == workspace)
                #expect(newLabel == nil)
                return HerdrCreatedPane(workspaceID: "w4", tabID: "w4:t2", paneID: "w4:p2")
            }, machinesProvider: { [machine] })
        store.hosts = [host]
        let model = HerdrNewAgentPopupModel(space: space)
        model.selectKind("OpenCode")
        #expect(model.step == .kind)
        #expect(!model.back())
        try await model.launchInSpace(store: store) { destination in
            #expect(destination?.id == (remote ? machine.id : nil))
            return [workspace]
        }
        #expect(store.focusedSession?.agent.machineID == host.id)
        #expect(store.focusedSession?.agent.workspace == "demo")
        #expect(store.focusedSession?.agent.pane == "w4:p2")
        store.closeAll()
    }

    @Test func spaceLaunchDoesNotCreateAReplacementForAMissingOrAmbiguousSpace() async throws {
        let host = HerdrHostSnapshot.local(herdrPresent: true)
        let space = try #require(HerdrAgentSpace.group([spaceAgent(host)]).first)
        let store = HerdrStore(newAgentLauncher: { _, _, _, _ in
            Issue.record("An unavailable space must not launch an agent")
            throw HerdrNewAgentPopupModel.LaunchError.spaceUnavailable
        })
        store.hosts = [host]
        let model = HerdrNewAgentPopupModel(space: space)
        model.selectKind("OpenCode")
        let duplicate = HerdrWorkspaceSummary(id: "w4", label: "demo", tabCount: 1, paneCount: 1)
        for workspaces in [[], [duplicate, duplicate]] {
            await #expect(throws: HerdrNewAgentPopupModel.LaunchError.self) {
                try await model.launchInSpace(store: store) { _ in workspaces }
            }
        }
        #expect(store.tabs.isEmpty)
    }

    @Test func aRemovedRemoteMachineCannotFallBackToThisMac() async throws {
        let host = HerdrHostSnapshot(
            id: "missing", name: "Demo server", isLocal: false,
            herdrPresent: true, reachable: true)
        let space = try #require(HerdrAgentSpace.group([spaceAgent(host)]).first)
        let store = HerdrStore(machinesProvider: { [] })
        store.hosts = [host]
        let model = HerdrNewAgentPopupModel(space: space)
        model.selectKind("OpenCode")
        await #expect(throws: HerdrQuinjetError.self) {
            try await model.launchInSpace(store: store) { _ in
                Issue.record("A removed remote machine must not query local workspaces")
                return []
            }
        }
        #expect(store.tabs.isEmpty)
    }

    @Test func sameNamedSpacesOnDifferentMachinesStaySeparate() {
        let local = spaceAgent(.local(herdrPresent: true))
        let remote = spaceAgent(
            HerdrHostSnapshot(
                id: "remote", name: "Demo server", isLocal: false,
                herdrPresent: true, reachable: true))
        let spaces = HerdrAgentSpace.group([local, remote])
        #expect(spaces.count == 2)
        #expect(Set(spaces.map(\.id)).count == 2)
        #expect(spaces.allSatisfy { $0.agents.count == 1 && $0.title == "demo" })
    }

    private func spaceAgent(_ host: HerdrHostSnapshot) -> HerdrAgent {
        HerdrAgent.make(
            machineID: host.id, machineName: host.name, machineIsLocal: host.isLocal,
            sshTarget: nil, session: "default", pane: "w4:p1", kind: "OpenCode", status: .idle,
            title: "Review demo", workspace: "demo", cwd: "/demo")
    }
}
