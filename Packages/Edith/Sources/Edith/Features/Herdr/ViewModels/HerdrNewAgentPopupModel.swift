import EdithKit
import Foundation

@MainActor
@Observable
final class HerdrNewAgentPopupModel {
    enum Step: Equatable {
        case kind
        case machine
        case space
    }

    var step = Step.kind
    var kindQuery = ""
    var selectedKind: String?
    var machineQuery = ""
    var selectedHost: HerdrHostSnapshot?
    var spaceQuery = ""
    var selectedSpace: HerdrWorkspaceSummary?
    var workspaces: [HerdrWorkspaceSummary] = []
    var loadingWorkspaces = false
    var errorMessage: String?
    var launching = false

    static func matchingKinds(_ query: String) -> [String] {
        guard !query.isEmpty else { return HerdrKind.filterLabels }
        return HerdrKind.filterLabels.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    static func matchingMachines(_ query: String, in hosts: [HerdrHostSnapshot])
        -> [HerdrHostSnapshot]
    {
        guard !query.isEmpty else { return hosts }
        return hosts.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    static func matchingSpaces(_ query: String, in workspaces: [HerdrWorkspaceSummary])
        -> [HerdrWorkspaceSummary]
    {
        guard !query.isEmpty else { return workspaces }
        return workspaces.filter { $0.label.localizedCaseInsensitiveContains(query) }
    }

    static func matchingSpace(named query: String, in workspaces: [HerdrWorkspaceSummary])
        -> HerdrWorkspaceSummary?
    {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return workspaces.first {
            $0.label.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    func selectKind(_ kind: String) {
        selectedKind = kind
        step = .machine
    }

    func selectMachine(_ host: HerdrHostSnapshot) {
        guard host.reachable, host.herdrPresent else { return }
        selectedHost = host
        step = .space
    }

    @discardableResult
    func back() -> Bool {
        switch step {
        case .kind:
            return false
        case .machine:
            step = .kind
            return true
        case .space:
            step = .machine
            return true
        }
    }
}
