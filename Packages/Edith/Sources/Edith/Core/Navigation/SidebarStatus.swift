import EdithKit
import Foundation
import Observation
import SwiftUI

struct SidebarBadge: Equatable {
    enum Tone: Equatable {
        case neutral
        case accent
        case warning
    }

    let text: String
    let tone: Tone

    init(_ text: String, tone: Tone = .neutral) {
        self.text = text
        self.tone = tone
    }
}

enum SidebarBadgeFormat {
    static func sessions(working: Int) -> SidebarBadge? {
        guard working > 0 else { return nil }
        return SidebarBadge("\(working) working", tone: .accent)
    }

    static func limits(session: Double?, weekly: Double?) -> SidebarBadge? {
        let parts = [session, weekly].compactMap { value -> String? in
            guard let value else { return nil }
            return "\(Int(value.rounded()))%"
        }
        guard !parts.isEmpty else { return nil }
        let highest = [session, weekly].compactMap { $0 }.max() ?? 0
        return SidebarBadge(
            parts.joined(separator: " · "), tone: highest >= 80 ? .warning : .neutral)
    }

    static func count(_ value: Int) -> SidebarBadge? {
        guard value > 0 else { return nil }
        return SidebarBadge(String(value), tone: .accent)
    }

    static func bytes(_ value: Int64) -> SidebarBadge? {
        guard value > 0 else { return nil }
        return SidebarBadge(JunkScanner.format(value))
    }

    static func agentSummary(jobs: [AgentJobSnapshot], cpu: Double) -> String {
        let live = jobs.filter { $0.subscribers > 0 }.count
        return "\(jobs.count) jobs · \(live) live · \(String(format: "%.1f", cpu))% CPU"
    }
}

@MainActor
@Observable
final class SidebarStatusModel {
    var sessionsWorking = 0
    var sessionPercent: Double?
    var weeklyPercent: Double?
    var updatesAvailable = 0
    var reclaimableBytes: Int64 = 0
    var agentRunning = false
    var agentSummary = ""

    private var refreshTask: Task<Void, Never>?

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() {
        refreshAgent()
        refreshSessions()
        refreshLimits()
        refreshMaintenance()
    }

    private func refreshSessions() {
        guard ExtensionRegistry.entry("herdr")?.isEnabled(in: SharedDefaults.store) == true
        else {
            sessionsWorking = 0
            return
        }
        let live = HerdrStore.shared.agents.filter { $0.status == .working }.count
        if live > 0 || !HerdrStore.shared.agents.isEmpty {
            SidebarBadgeStore.recordSessions(working: live)
            sessionsWorking = live
        } else {
            sessionsWorking = SidebarBadgeStore.sessionsWorking()
        }
    }

    private func refreshLimits() {
        guard ExtensionRegistry.entry("usage")?.isEnabled(in: SharedDefaults.store) == true
        else {
            sessionPercent = nil
            weeklyPercent = nil
            return
        }
        let provider =
            LimitProvider(
                rawValue: SharedDefaults.store.string(forKey: AppStorageKeys.Limits.provider)
                    ?? "") ?? .claude
        let latest = LimitsHistory.latest(provider: provider)
        sessionPercent = latest?.session?.percent
        weeklyPercent = latest?.week?.percent
    }

    private func refreshMaintenance() {
        let maintenanceOn =
            ExtensionRegistry.entry("appMaintenance")?.isEnabled(in: SharedDefaults.store) == true
        let cleanerOn =
            ExtensionRegistry.entry("cleaner")?.isEnabled(in: SharedDefaults.store) == true
        updatesAvailable = maintenanceOn ? SidebarBadgeStore.updatesAvailable() : 0
        reclaimableBytes = cleanerOn ? SidebarBadgeStore.reclaimableBytes() : 0
    }

    private func refreshAgent() {
        guard let runtime = try? AgentClient.shared.runtimeSnapshot(),
            let jobs = try? AgentClient.shared.jobSnapshots()
        else {
            agentRunning = false
            agentSummary = AgentRegistrationState.current.title
            return
        }
        agentRunning = true
        agentSummary = SidebarBadgeFormat.agentSummary(jobs: jobs, cpu: runtime.cpuPercent)
    }

    func badge(pageID: String) -> SidebarBadge? {
        switch pageID {
        case MainDestination.herdr.rawValue:
            SidebarBadgeFormat.sessions(working: sessionsWorking)
        case MainDestination.dashboard.rawValue:
            SidebarBadgeFormat.limits(session: sessionPercent, weekly: weeklyPercent)
        default:
            nil
        }
    }

    func badge(childID: String, of parent: String) -> SidebarBadge? {
        guard parent == MainDestination.appMaintenance.rawValue else { return nil }
        switch childID {
        case AppMaintenanceSection.updates.rawValue:
            return SidebarBadgeFormat.count(updatesAvailable)
        case AppMaintenanceSection.cleaner.rawValue:
            return SidebarBadgeFormat.bytes(reclaimableBytes)
        default:
            return nil
        }
    }
}

@MainActor
enum SidebarStatus {
    static let shared = SidebarStatusModel()
}

struct AgentStatusBar: View {
    let theme: Color
    @State private var status = SidebarStatus.shared
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled

    var body: some View {
        Button {
            SharedDefaults.store.set(
                SettingsPane.Tab.agent.rawValue, forKey: AppStorageKeys.General.settingsTab)
            SharedDefaults.store.set(
                MainDestination.settings.rawValue, forKey: AppStorageKeys.General.mainWindowSection)
        } label: {
            HStack(spacing: UIScale.pt(7)) {
                Circle()
                    .fill(status.agentRunning ? DashSkin.sage : Color.orange)
                    .frame(width: UIScale.pt(6), height: UIScale.pt(6))
                Text("edithd")
                    .font(DashSkin.mono(10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(status.agentSummary)
                    .font(DashSkin.mono(10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, UIScale.pt(11))
            .frame(height: UIScale.pt(24))
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .help("Open Background agent settings")
        .onAppear {
            guard automaticActionsEnabled else { return }
            status.start()
        }
    }
}
