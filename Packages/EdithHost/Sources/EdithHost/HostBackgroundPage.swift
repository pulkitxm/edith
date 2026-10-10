import AppKit
import EdithExtensionUI
import SwiftUI

struct HostBackgroundPage: View {
    @Bindable var services: HostCoreServices
    private let presenter: (any HostExtensionContentPresenting)?
    @State private var showingEvents = false
    @State private var model: HostBackgroundModel

    init(
        services: HostCoreServices, model: HostBackgroundModel? = nil,
        presenter: (any HostExtensionContentPresenting)? = nil
    ) {
        self.services = services
        self.presenter = presenter
        _model = State(
            initialValue: model
                ?? HostBackgroundModel(environment: HostBackgroundSource.live(services)))
    }

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent(
                    "Registration", value: services.online ? "Running with Edith" : "Not running")
                if let runtime = services.snapshot {
                    LabeledContent(
                        "Uptime",
                        value: Duration.seconds(max(0, Date().timeIntervalSince(runtime.startedAt)))
                            .formatted(
                                .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))
                    LabeledContent(
                        "Memory",
                        value: ByteCountFormatter.string(
                            fromByteCount: Int64(clamping: runtime.residentBytes),
                            countStyle: .memory))
                    LabeledContent("CPU", value: String(format: "%.1f%%", services.cpuPercent))
                    DisclosureGroup("Technical details") {
                        LabeledContent(
                            "Build",
                            value: Bundle.main.object(
                                forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                                ?? "Development")
                        LabeledContent("Process", value: String(runtime.pid))
                        LabeledContent("Store", value: "Private task journal")
                    }
                }
                HStack {
                    Button("Restart") { Task { await services.restart() } }.disabled(
                        services.starting)
                    Button("Copy log command") { services.copyLogCommand() }
                }
                if let failure = services.panelFailure {
                    Text(failure).settingsCaption().foregroundStyle(.orange)
                }
                if let failure = services.failure {
                    Text(failure).settingsCaption().foregroundStyle(.orange)
                }
            }
            Section("Behaviour") {
                Text("Pause ambient jobs on battery is unavailable in this background service.")
                    .settingsCaption()
                Text("The scheduler must support this policy before it can be changed.")
                    .settingsCaption()
            }
            if let presenter {
                HostBackgroundNotificationSection(
                    marketplace: services.marketplace, presenter: presenter)
            }
            HostBackgroundJobsSection(model: model)
            Section("Background tasks") {
                if services.snapshot?.tasks.isEmpty != false {
                    Text("Long-running actions appear here with their progress and result.")
                        .settingsCaption()
                }
                ForEach((services.snapshot?.tasks ?? []).reversed()) { task in
                    DisclosureGroup {
                        LabeledContent("Task", value: task.id.uuidString)
                        LabeledContent("Submitted", value: task.startedAt.formatted())
                        if let finished = task.finishedAt {
                            LabeledContent("Finished", value: finished.formatted())
                        }
                        if let message = task.message { Text(message).textSelection(.enabled) }
                        if task.phase == .running {
                            Button("Cancel task") { services.cancelTask(task.id) }
                        }
                    } label: {
                        HStack {
                            Text(task.title); Spacer();
                            Text(task.phase.rawValue.capitalized).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Completed tasks remain available after restarting Edith.").settingsCaption()
            }
            Section("Diagnostics") { Button("Event timeline") { showingEvents = true } }
        }
        .edithForm()
        .edithSheet(isPresented: $showingEvents) {
            HostBackgroundEventTimeline(model: model)
        }
        .pageTask(id: services.snapshot?.collectedAt, cancel: model.cancel) {
            await model.refresh()
        }
    }
}
