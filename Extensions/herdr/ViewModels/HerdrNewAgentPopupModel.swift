import EdithExtensionSupport
import EdithExtensionUI
import Foundation

@MainActor
@Observable
final class HerdrNewAgentPopupModel {
    enum LaunchError: LocalizedError {
        case spaceUnavailable

        var errorDescription: String? {
            "This space is no longer available. Refresh the agent list and try again."
        }
    }

    enum Step: Equatable {
        case kind
        case machine
        case space
    }

    enum LayoutChoice: String, CaseIterable, Identifiable {
        case newTab
        case sideBySide

        var id: String { rawValue }

        var title: String {
            switch self {
            case .newTab: "New Tab"
            case .sideBySide: "Side by Side"
            }
        }

        var symbolName: String {
            switch self {
            case .newTab: "plus.rectangle"
            case .sideBySide: "rectangle.split.2x1"
            }
        }
    }

    var step = Step.kind
    var layoutChoice: LayoutChoice {
        didSet { onLayoutChange(layoutChoice) }
    }
    private let onLayoutChange: (LayoutChoice) -> Void
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
    let space: HerdrAgentSpace?

    init(
        space: HerdrAgentSpace? = nil, layoutChoice: LayoutChoice = .newTab,
        onLayoutChange: @escaping (LayoutChoice) -> Void = { _ in }
    ) {
        self.space = space
        self.layoutChoice = layoutChoice
        self.onLayoutChange = onLayoutChange
    }

    func launchInSpace(
        store: HerdrStore,
        listWorkspaces: (Machine?) async throws -> [HerdrWorkspaceSummary] = {
            try await HerdrLaunchOperations.listWorkspaces(on: $0)
        }
    ) async throws {
        guard let space, let kind = selectedKind,
            let machineID = space.agents.first?.machineID,
            space.agents.allSatisfy({ $0.machineID == machineID }),
            let host = store.hosts.first(where: { $0.id == machineID }),
            host.reachable, host.herdrPresent
        else { throw LaunchError.spaceUnavailable }
        let machine = store.machine(for: host)
        guard store.uiClient != nil || host.isLocal || machine != nil else {
            throw HerdrQuinjetError.machineUnavailable
        }
        let workspaces: [HerdrWorkspaceSummary]
        if store.uiClient == nil {
            workspaces = try await listWorkspaces(machine)
        } else {
            workspaces = try await store.listWorkspaces(for: host)
        }
        let matches = workspaces.filter { $0.label == space.title || $0.id == space.title }
        guard matches.count == 1, let workspace = matches.first else {
            throw LaunchError.spaceUnavailable
        }
        try await store.launchNewAgent(
            kind: kind, host: host, existingSpace: workspace, newSpaceLabel: nil)
    }

    nonisolated static func matchingKinds(_ query: String) -> [String] {
        guard !query.isEmpty else { return HerdrKind.filterLabels }
        return HerdrKind.filterLabels.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    nonisolated static func matchingMachines(_ query: String, in hosts: [HerdrHostSnapshot])
        -> [HerdrHostSnapshot]
    {
        guard !query.isEmpty else { return hosts }
        return hosts.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    nonisolated static func matchingSpaces(_ query: String, in workspaces: [HerdrWorkspaceSummary])
        -> [HerdrWorkspaceSummary]
    {
        guard !query.isEmpty else { return workspaces }
        return workspaces.filter { $0.label.localizedCaseInsensitiveContains(query) }
    }

    nonisolated static func matchingSpace(
        named query: String, in workspaces: [HerdrWorkspaceSummary]
    )
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
        if space == nil { step = .machine }
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
