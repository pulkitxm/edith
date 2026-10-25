import AppKit
import EdithExtensionUI
import ServiceManagement
import SwiftUI

struct HostBackgroundPage: View {
    @Bindable var services: HostCoreServices
    private let presenter: (any HostExtensionContentPresenting)?
    @State private var showingEvents = false
    @State private var model: HostBackgroundModel
    @State private var policy: HostBackgroundPolicyModel

    init(
        services: HostCoreServices, model: HostBackgroundModel? = nil,
        presenter: (any HostExtensionContentPresenting)? = nil,
        policy: HostBackgroundPolicyModel? = nil
    ) {
        self.services = services
        self.presenter = presenter
        _model = State(
            initialValue: model
                ?? HostBackgroundModel(environment: HostBackgroundSource.live(services)))
        _policy = State(
            initialValue: policy
                ?? HostBackgroundPolicyModel(environment: HostBackgroundSource.policy(services)))
    }

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Registration", value: HostLoginItem.registration.title)
                if let runtime = services.snapshot {
                    LabeledContent(
                        "Uptime",
                        value: HostCompactDuration.text(Date().timeIntervalSince(runtime.startedAt))
                    )
                    LabeledContent(
                        "Memory",
                        value: ByteCountFormatter.string(
                            fromByteCount: Int64(clamping: runtime.residentBytes),
                            countStyle: .memory))
                    LabeledContent("CPU", value: String(format: "%.1f%%", services.cpuPercent))
                    DisclosureGroup("Technical details") {
                        LabeledContent(
                            "Build",
                            value: runtime.agent?.build
                                ?? Bundle.main.object(
                                    forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                                ?? "Development")
                        LabeledContent("Process", value: String(runtime.pid))
                        if let schema = runtime.agent?.schemaVersion {
                            LabeledContent("Store schema", value: String(schema))
                        }
                    }
                } else if services.starting {
                    SkeletonGroup {
                        ForEach(["Uptime", "Memory", "CPU"], id: \.self) { title in
                            LabeledContent(title) { SkeletonBlock(width: 90, height: 12) }
                        }
                    }
                }
                HStack {
                    Button("Restart") { Task { await services.restart() } }.disabled(
                        services.starting || services.snapshot == nil)
                    Button("Copy log command") { services.copyLogCommand() }
                    if HostLoginItem.registration.needsAttention {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if HostLoginItem.registration == .awaitingApproval {
                    Text(
                        "macOS is waiting for you to allow Edith's background agent in "
                            + "Login Items and Extensions."
                    ).settingsCaption()
                }
                if let failure = services.panelFailure {
                    Text(failure).settingsCaption().foregroundStyle(.orange)
                }
                if let failure = services.failure {
                    Text(failure).settingsCaption().foregroundStyle(.orange)
                }
            }
            HostBackgroundPolicySection(model: policy)
            if let presenter {
                HostBackgroundNotificationSection(
                    marketplace: services.marketplace, presenter: presenter)
            }
            HostBackgroundJobsSection(model: model)
            HostBackgroundTasksSection(services: services)
            Section("Diagnostics") {
                Button {
                    showingEvents = true
                } label: {
                    HStack {
                        Label("Event timeline", systemImage: "waveform.path.ecg")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: UIScale.pt(10), weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: UIScale.pt(16), height: UIScale.pt(20))
                    }
                    .padding(.vertical, 6)
                    .padding(.trailing, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.edith(.borderless))
            }
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
