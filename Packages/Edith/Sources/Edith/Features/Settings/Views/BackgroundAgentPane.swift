import AppKit
import EdithKit
import SwiftUI

@MainActor
@Observable
final class BackgroundAgentModel {
    var registration: AgentRegistrationState = .current
    var runtime: AgentRuntimeSnapshot?
    var jobs: [AgentJobSnapshot] = []
    var failure: String?

    func refresh() async {
        registration = .current
        let result = await AgentQuery.value {
            (try AgentClient.shared.runtimeSnapshot(), try AgentClient.shared.jobSnapshots())
        }
        switch result {
        case let .success(value):
            runtime = value.0
            jobs = value.1
            failure = nil
        case let .failure(error):
            runtime = nil
            jobs = []
            failure = error.localizedDescription
        }
    }

    func restart() async {
        await AgentQuery.run { try AgentClient.shared.restart() }
        try? await Task.sleep(for: .milliseconds(1_500))
        await refresh()
    }

    func copyLogCommand() {
        let script =
            "log show --style compact --last 1h --predicate 'subsystem == "
            + "\"\(AgentService.machServiceName)\"'"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(script, forType: .string)
    }
}

struct BackgroundAgentPane: View {
    @State private var model = BackgroundAgentModel()
    @AppStorage(AgentSettingsKeys.pauseAmbientOnBattery, store: SharedDefaults.store) private
        var pauseAmbientOnBattery = false
    @AppStorage(AgentSettingsKeys.notifyWhenBlocked, store: SharedDefaults.store) private
        var notifyWhenBlocked = false
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        Form {
            statusSection
            behaviourSection
            jobsSection
        }
        .formStyle(.grouped)
        .task {
            guard automaticActionsEnabled else { return }
            await model.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await model.refresh()
            }
        }
    }

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Registration", value: model.registration.title)
            if let runtime = model.runtime {
                LabeledContent("Build", value: runtime.build)
                LabeledContent("Process", value: String(runtime.processIdentifier))
                LabeledContent("Uptime", value: AgentDuration.text(runtime.uptime))
                LabeledContent(
                    "Memory",
                    value: ByteCountFormatter.string(
                        fromByteCount: Int64(runtime.residentBytes), countStyle: .memory))
                LabeledContent("CPU", value: String(format: "%.1f%%", runtime.cpuPercent))
                LabeledContent("Subscribers", value: String(runtime.subscriberCount))
                LabeledContent("Store schema", value: String(runtime.schemaVersion))
            } else if let failure = model.failure {
                Text(failure)
                    .settingsCaption()
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("Restart") { Task { await model.restart() } }
                    .disabled(model.runtime == nil)
                Button("Copy log command") { model.copyLogCommand() }
                if model.registration.needsAttention {
                    Button("Open Login Items") {
                        AgentRegistrar.openLoginItemsSettings()
                    }
                }
            }
            if model.registration == .awaitingApproval {
                Text(
                    "macOS is waiting for you to allow Edith's background agent in "
                        + "Login Items and Extensions."
                )
                .settingsCaption()
            }
        }
    }

    private var behaviourSection: some View {
        Section("Behaviour") {
            Toggle(
                "Pause ambient jobs on battery",
                isOn: $pauseAmbientOnBattery.configured(AgentSettingsKeys.pauseAmbientOnBattery))
            Toggle(
                "Notify when an agent blocks",
                isOn: $notifyWhenBlocked.configured(AgentSettingsKeys.notifyWhenBlocked))
            Text("Live jobs keep running while a page is open, whatever these say.")
                .settingsCaption()
        }
    }

    private var jobsSection: some View {
        Section("Jobs") {
            if model.jobs.isEmpty {
                Text("The agent has not reported any jobs yet.")
                    .settingsCaption()
            } else {
                ForEach(model.jobs) { job in
                    AgentJobRow(job: job, dark: dark)
                }
            }
        }
    }
}

private struct AgentJobRow: View {
    let job: AgentJobSnapshot
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
            HStack(spacing: UIScale.pt(8)) {
                Text(job.descriptor.title)
                    .font(.system(size: UIScale.pt(12.5), weight: .medium))
                Spacer(minLength: 0)
                Text(job.phase.title)
                    .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                    .foregroundStyle(job.phase == .failed ? .orange : .secondary)
            }
            HStack(spacing: UIScale.pt(10)) {
                Text(job.descriptor.trigger.title)
                Text(AgentDuration.cadence(job.descriptor.cadence))
                Text(job.descriptor.power.title)
                if job.subscribers > 0 {
                    Text("\(job.subscribers) watching")
                }
                if let last = job.lastRun {
                    Text("last \(AgentDuration.text(Date().timeIntervalSince(last))) ago")
                }
            }
            .font(.system(size: UIScale.pt(10.5)))
            .foregroundStyle(.tertiary)
            if let error = job.lastError {
                Text(error)
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(.orange)
            }
        }
    }
}

enum AgentDuration {
    static func text(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }

    static func cadence(_ cadence: AgentCadence) -> String {
        let ambient = cadence.ambient.map(text) ?? "on demand"
        guard let live = cadence.live else { return ambient }
        return "\(ambient), live \(text(live))"
    }
}
