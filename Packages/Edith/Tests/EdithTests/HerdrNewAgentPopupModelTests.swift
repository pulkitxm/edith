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
}
