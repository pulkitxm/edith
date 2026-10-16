import AppKit
import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostBackgroundPolicySection: View {
    @Bindable var model: HostBackgroundPolicyModel

    var body: some View {
        Section("Behaviour") {
            if let value = model.value {
                Toggle(
                    "Pause ambient jobs on battery",
                    isOn: Binding(
                        get: { model.value ?? value },
                        set: { requested in Task { await model.set(requested) } })
                )
                .disabled(model.saving || model.load.isRunning)
            } else {
                LabeledContent("Pause ambient jobs on battery", value: "Unavailable")
            }
            if model.load.isRunning || model.saving { LoadingIndicator() }
            Text(
                "Applies to automatic ambient jobs. Jobs with an active page subscription continue on battery. Work already running and manual actions continue."
            ).settingsCaption()
            LabeledContent("Global policy", value: model.propagationLabel)
            if let propagation = model.propagation {
                ForEach(propagation.owners.filter { !$0.applied }, id: \.identity.id) { owner in
                    LabeledContent(owner.identity.id, value: owner.applied ? "Applied" : "Failed")
                    if let failure = owner.failure {
                        Text(failure).settingsCaption().foregroundStyle(.orange)
                    }
                }
            }
            Text("Jobs with fixed battery restrictions still pause on battery.").settingsCaption()
            if let failure = model.failure {
                Text(failure).settingsCaption().foregroundStyle(.orange)
            }
            Button(model.failure == nil ? "Reload policy" : "Retry") {
                Task { await model.refresh() }
            }
            .disabled(model.owner == nil || model.load.isRunning || model.saving)
        }
        .pageTask(id: model.owner, cancel: model.cancel) { await model.refresh() }
    }
}

enum HostCompactDuration {
    static func text(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}

struct HostBackgroundRowsSkeleton: View {
    var count: Int

    var body: some View {
        SkeletonGroup {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonBlock(width: 160, height: 12)
                        SkeletonBlock(height: 10)
                    }
                    Spacer(minLength: 30)
                    SkeletonBlock(width: 48, height: 10)
                }
                .padding(.vertical, 6)
            }
        }
    }
}

struct HostBackgroundJobsSection: View {
    @Bindable var model: HostBackgroundModel

    var body: some View {
        Section("Jobs") {
            if model.load.state == .loading && model.jobs.isEmpty {
                HostBackgroundRowsSkeleton(count: 4)
            }
            if let unavailable = model.unavailable {
                Text(unavailable).settingsCaption().foregroundStyle(.secondary)
            }
            if let failure = model.failure {
                Text(failure).settingsCaption().foregroundStyle(.orange)
                Button("Reload") { Task { await model.refresh() } }
            }
            if model.jobs.isEmpty && model.unavailable == nil && !model.load.isRunning {
                Text("The agent has not reported any jobs yet.").settingsCaption()
            }
            ForEach(model.jobs) { job in
                HStack {
                    HostBackgroundJobRow(job: job)
                    Button(job.phase == "running" ? "Cancel" : "Run now") {
                        Task { await model.control(job) }
                    }
                    .disabled(
                        !model.current || model.action != nil
                            || (job.phase != "running" && !job.canRun)
                    )
                    .help(
                        job.phase == "running"
                            ? "Cancel this job" : "Run this job in the background")
                }
            }
        }
    }
}

struct HostBackgroundJobRow: View {
    let job: HostBackgroundJob

    private var cadence: String {
        let ambient = job.descriptor.cadence.ambient.map(HostCompactDuration.text) ?? "on demand"
        guard let live = job.descriptor.cadence.live else { return ambient }
        return "\(ambient), live \(HostCompactDuration.text(live))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
            HStack(spacing: UIScale.pt(8)) {
                Text(job.descriptor.title)
                    .font(.system(size: UIScale.pt(12.5), weight: .medium))
                Spacer(minLength: 0)
                Text(HostCoreJobPhase(rawValue: job.phase)?.title ?? job.phase.capitalized)
                    .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                    .foregroundStyle(job.phase == "failed" ? .orange : .secondary)
            }
            HStack(spacing: UIScale.pt(10)) {
                Text(
                    HostCoreJobTrigger(rawValue: job.descriptor.trigger)?.title
                        ?? job.descriptor.trigger.capitalized)
                Text(cadence)
                Text(
                    HostCoreJobPower(rawValue: job.descriptor.power)?.title ?? job.descriptor.power)
                if job.subscribers > 0 {
                    Text("\(job.subscribers) watching")
                }
                if let last = job.lastRun {
                    Text("last \(HostCompactDuration.text(Date().timeIntervalSince(last))) ago")
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

struct HostBackgroundTasksSection: View {
    @Bindable var services: HostCoreServices
    @State private var expandedID: UUID?

    private struct Row: Identifiable {
        let id: UUID
        let title: String
        let activity: String?
        let state: String
        let terminal: Bool
        let attention: Bool
        let operation: String?
        let submitted: Date
        let started: Date?
        let finished: Date?
        let failure: String?
        let cancellable: Bool
    }

    private var rows: [Row] {
        let core = (services.snapshot?.tasks ?? []).map {
            Row(
                id: $0.id, title: $0.title, activity: nil, state: $0.phase.rawValue.capitalized,
                terminal: $0.phase != .running, attention: $0.phase == .failed, operation: nil,
                submitted: $0.startedAt, started: $0.startedAt, finished: $0.finishedAt,
                failure: $0.message, cancellable: $0.phase == .running)
        }
        let commands = (services.snapshot?.commandTasks ?? []).map {
            Row(
                id: $0.id, title: $0.title, activity: $0.lastActivity,
                state: $0.state.rawValue.capitalized, terminal: $0.state.isTerminal,
                attention: $0.state == .failed || $0.state == .interrupted,
                operation: $0.operation, submitted: $0.submittedAt, started: $0.startedAt,
                finished: $0.finishedAt, failure: $0.failure, cancellable: false)
        }
        return (core + commands).sorted {
            if $0.terminal != $1.terminal { return !$0.terminal }
            return $0.submitted > $1.submitted
        }
    }

    var body: some View {
        let ordered = rows
        Section {
            if services.snapshot == nil && services.starting {
                HostBackgroundRowsSkeleton(count: 3)
            } else if ordered.isEmpty {
                Text("Long-running actions appear here with their progress and result.")
                    .settingsCaption()
            }
            ForEach(ordered) { task in
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedID == task.id },
                        set: { expandedID = $0 ? task.id : nil })
                ) {
                    details(task)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.title).fontWeight(.medium)
                            if let activity = task.activity {
                                Text(activity).font(.edithText(.caption)).foregroundStyle(
                                    .secondary
                                )
                                .lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(task.state)
                            .font(.edithText(.caption))
                            .foregroundStyle(task.attention ? .orange : .secondary)
                    }
                }
            }
        } header: {
            HStack {
                Text("Background tasks")
                Spacer()
                Text("\(ordered.filter { !$0.terminal }.count) active")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text(
                "Completed tasks remain available after restarting Edith. "
                    + "Command output may contain information from the tools you run.")
        }
    }

    @ViewBuilder
    private func details(_ task: Row) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Task", value: task.id.uuidString).textSelection(.enabled)
            if let operation = task.operation {
                LabeledContent("Operation", value: operation)
            }
            LabeledContent("Submitted", value: task.submitted.formatted())
            if let started = task.started {
                LabeledContent("Started", value: started.formatted())
            }
            if let finished = task.finished {
                LabeledContent("Finished", value: finished.formatted())
            }
            if let failure = task.failure {
                Text(failure).foregroundStyle(.orange).textSelection(.enabled)
            }
            if task.cancellable {
                Button("Cancel task") { services.cancelTask(task.id) }
            }
        }
        .font(.edithText(.caption))
        .padding(.vertical, 8)
    }
}

struct HostBackgroundEventTimeline: View {
    @Bindable var model: HostBackgroundModel
    @State private var timeline: HostBackgroundTimelineModel
    @Environment(\.dismiss) private var dismiss

    init(model: HostBackgroundModel) {
        self.model = model
        let timeline = HostBackgroundTimelineModel()
        timeline.receive(model.events)
        _timeline = State(initialValue: timeline)
    }

    var body: some View {
        Form {
            Section("Event timeline") {
                TextField("Search events", text: $timeline.search)
                Toggle("Failures only", isOn: $timeline.failuresOnly)
                HStack {
                    Button(timeline.paused ? "Resume" : "Pause") {
                        timeline.paused.toggle()
                        timeline.receive(model.events)
                    }
                    Button("Copy events") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(timeline.text, forType: .string)
                    }.disabled(timeline.matches.isEmpty)
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                if timeline.matches.isEmpty {
                    Text(
                        model.failure ?? model.unavailable
                            ?? (timeline.events.isEmpty
                                ? "No background events have been recorded."
                                : "No matching events.")
                    )
                    .settingsCaption()
                }
                ForEach(timeline.visibleEvents) { event in
                    VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                        HStack {
                            Text(event.name)
                            Spacer()
                            Text(event.level.capitalized)
                                .foregroundStyle(
                                    event.level == "error"
                                        ? .red : event.level == "warning" ? .orange : .secondary)
                        }
                        Text(event.message).textSelection(.enabled)
                        Text(event.date.formatted() + " · " + event.category).settingsCaption()
                        if let duration = event.duration {
                            Text(
                                Duration.seconds(duration).formatted(
                                    .units(
                                        allowed: [.hours, .minutes, .seconds], width: .abbreviated))
                            ).settingsCaption()
                        }
                        if let task = event.taskID {
                            Text(task.uuidString).settingsCaption().textSelection(.enabled)
                        }
                    }
                }
                if timeline.hasMore {
                    Button("Load more events") { timeline.loadMore() }
                }
            }
        }
        .edithForm()
        .onChange(of: model.events) { _, events in timeline.receive(events) }
    }
}
