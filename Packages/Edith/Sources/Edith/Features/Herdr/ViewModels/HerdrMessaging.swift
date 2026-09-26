import EdithKit
import Foundation
import Observation

enum HerdrBroadcastGroup: String, CaseIterable, Identifiable {
    case working
    case stopped

    var id: String { rawValue }

    var title: String {
        switch self {
        case .working: "Working Agents"
        case .stopped: "Stopped Agents"
        }
    }

    var detail: String {
        switch self {
        case .working: "Agents in the middle of a turn. They read it when they can."
        case .stopped: "Idle and finished agents waiting at their prompt."
        }
    }

    func contains(_ status: HerdrAgentStatus) -> Bool {
        switch self {
        case .working: status == .working
        case .stopped: status == .idle || status == .done
        }
    }

    func recipients(from agents: [HerdrAgent]) -> [HerdrAgent] {
        agents.filter { !$0.isTerminal && contains($0.status) }
    }
}

struct HerdrMessageDraft: Identifiable, Equatable {
    enum Delivery: String, CaseIterable, Identifiable {
        case now
        case whenFinished
        case after
        case at

        var id: String { rawValue }

        var title: String {
            switch self {
            case .now: "Now"
            case .whenFinished: "When done"
            case .after: "Later"
            case .at: "At time"
            }
        }

        var detail: String {
            switch self {
            case .now: "Herdr types it in and presses Return."
            case .whenFinished: "Edith sends it once, the next time this agent finishes a turn."
            case .after: "Edith sends it after the delay you pick."
            case .at: "Edith sends it at the time you pick."
            }
        }
    }

    let id = UUID()
    var recipients: [HerdrAgent]
    var group: HerdrBroadcastGroup?
    var delivery: Delivery
    var presenterID: String?

    var single: HerdrAgent? { group == nil && recipients.count == 1 ? recipients[0] : nil }

    var title: String {
        if let group { return "Message \(group.title)" }
        if let single { return "Message \(single.title)" }
        return "Message \(recipients.count) Agents"
    }
}

@MainActor
@Observable
final class HerdrMessaging {
    typealias Broadcaster =
        @Sendable (String, [HerdrAgent]) async -> [String: HerdrPromptOutcome]
    typealias Arm =
        @Sendable (String, HerdrAgent, HerdrHookSchedule) async throws
        -> HerdrHooksSnapshot
    typealias Remove = @Sendable (UUID) async throws -> HerdrHooksSnapshot

    var hooks = HerdrHooksSnapshot()
    var draft: HerdrMessageDraft?
    var errorMessage: String?

    @ObservationIgnored private let broadcaster: Broadcaster
    @ObservationIgnored private let armer: Arm
    @ObservationIgnored private let remover: Remove

    init(
        broadcaster: @escaping Broadcaster = { await HerdrAgentPrompt.broadcast($0, to: $1) },
        arm: @escaping Arm = { try await HerdrHookClient().arm($0, for: $1, schedule: $2) },
        remove: @escaping Remove = { try await HerdrHookClient().remove($0) }
    ) {
        self.broadcaster = broadcaster
        armer = arm
        remover = remove
    }

    func adopt(_ snapshot: HerdrHooksSnapshot) {
        guard snapshot != hooks else { return }
        hooks = snapshot
    }

    func armedHook(for agentID: String) -> HerdrAgentHook? {
        hooks.armed(for: agentID)
    }

    func lastHook(for agentID: String) -> HerdrAgentHook? {
        hooks.latestSettled(for: agentID)
    }

    func compose(
        to agent: HerdrAgent, delivery: HerdrMessageDraft.Delivery = .now,
        presenterID: String? = nil
    ) {
        guard !agent.isTerminal else { return }
        errorMessage = nil
        draft = HerdrMessageDraft(
            recipients: [agent], group: nil, delivery: delivery, presenterID: presenterID)
    }

    func compose(_ group: HerdrBroadcastGroup, from agents: [HerdrAgent]) {
        let recipients = group.recipients(from: agents)
        guard !recipients.isEmpty else { return }
        errorMessage = nil
        draft = HerdrMessageDraft(
            recipients: recipients, group: group, delivery: .now, presenterID: nil)
    }

    func send(_ text: String, to agents: [HerdrAgent]) async -> [String: HerdrPromptOutcome] {
        guard let text = HerdrAgentPrompt.normalized(text), !agents.isEmpty else { return [:] }
        return await broadcaster(text, agents)
    }

    @discardableResult
    func arm(
        _ text: String, for agent: HerdrAgent, schedule: HerdrHookSchedule
    ) async -> Bool {
        guard let text = HerdrAgentPrompt.normalized(text) else { return false }
        do {
            adopt(try await armer(text, agent, schedule))
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func remove(_ id: UUID) async {
        do {
            adopt(try await remover(id))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
