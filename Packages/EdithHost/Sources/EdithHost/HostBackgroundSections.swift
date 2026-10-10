import AppKit
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
                    LabeledContent(
                        "Power",
                        value: job.descriptor.power == "pauseOnBattery"
                            ? "Paused on battery"
                            : job.descriptor.power == "pauseOnLock"
                                ? "Paused while locked" : "Always")
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
                    LabeledContent(
                        "Last status",
                        value: model.lastStatus(for: job)
                            ?? (job.lastRun == nil ? "Not run yet" : "Not reported"))
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
