import EdithExtensionUI
import SwiftUI

struct HostBackgroundJobsSection: View {
    @Bindable var model: HostBackgroundModel

    var body: some View {
        Section("Recurring jobs") {
            if model.load.state == .loading && model.jobs.isEmpty {
                LoadingIndicator()
            }
            if let unavailable = model.unavailable {
                Text(unavailable).settingsCaption().foregroundStyle(.secondary)
            }
            if let failure = model.failure {
                Text(failure).settingsCaption().foregroundStyle(.orange)
                Button("Reload") { Task { await model.refresh() } }
            }
            if model.jobs.isEmpty && model.unavailable == nil && !model.load.isRunning {
                Text("No recurring jobs are registered.").settingsCaption()
            }
            ForEach(model.jobs) { job in
                DisclosureGroup {
                    LabeledContent("Job", value: job.id)
                    LabeledContent("Trigger", value: job.descriptor.trigger.capitalized)
                    LabeledContent("Cadence", value: job.cadence)
                    LabeledContent("Live subscribers", value: String(job.subscribers))
                    if let lastRun = job.lastRun {
                        LabeledContent("Last run", value: lastRun.formatted())
                    } else {
                        LabeledContent("Last run", value: "Never")
                    }
                    if let duration = job.lastDuration {
                        LabeledContent(
                            "Last duration",
                            value: Duration.seconds(duration).formatted(
                                .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))
                    }
                    LabeledContent("Runs", value: String(job.runCount))
                    if let error = job.lastError {
                        Text(error).settingsCaption().foregroundStyle(.orange).textSelection(
                            .enabled)
                    }
                    Button(job.phase == "running" ? "Cancel" : "Run now") {
                        Task { await model.control(job) }
                    }
                    .disabled(
                        !model.current || model.action != nil
                            || (job.phase != "running" && !job.canRun))
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(job.descriptor.title)
                            Text(job.cadence).settingsCaption()
                        }
                        Spacer()
                        Text(job.phase.capitalized).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct HostBackgroundEventTimeline: View {
    @Bindable var model: HostBackgroundModel

    var body: some View {
        Form {
            Section("Event timeline") {
                if model.events.isEmpty {
                    Text(model.unavailable ?? "No background events have been recorded.")
                        .settingsCaption()
                }
                ForEach(model.events) { event in
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
            }
        }
        .edithForm()
    }
}
