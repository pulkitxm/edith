import AppKit
import EdithKit
import SwiftUI

private struct AgentHookPreview: Identifiable {
    var id = UUID()
    var plan: AgentActivityHookPlan
    var enabled: Bool
}

struct AgentConnectionsPane: View {
    @State private var settings = AgentActivitySettings.load()
    @State private var monitor = AgentActivityMonitor.shared
    @State private var project: URL?
    @State private var projectScope = false
    @State private var preview: AgentHookPreview?
    @State private var working = false
    @State private var error: String?
    @State private var result: String?
    @AppStorage(AppStorageKeys.Tabs.herdrEnabled, store: SharedDefaults.store) private
        var discovery = false
    @AppStorage(AgentSettingsKeys.stuckMinutes, store: SharedDefaults.store) private
        var stuckMinutes = 10
    private let installer: AgentActivityHookInstaller

    init(installer: AgentActivityHookInstaller? = nil) {
        self.installer =
            installer
            ?? AgentActivityHookInstaller(
                executable: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ed"))
    }

    var body: some View {
        Form {
            Section("Provider hooks") {
                Text(
                    "Connect live session activity to Home and Notch. Permission approvals are a separate opt-in and apply to one request at a time."
                )
                .font(.edithText(.callout)).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red).font(.edithText(.callout)) }
                if let result {
                    Text(result).foregroundStyle(.secondary).font(.edithText(.callout))
                        .textSelection(.enabled)
                }
                Toggle("Configure a project instead of global hooks", isOn: $projectScope)
                if projectScope {
                    HStack {
                        Text(project?.path ?? "Choose a project folder").lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose folder") { chooseProject() }.buttonStyle(.edith(.secondary))
                    }
                }
                ForEach(AgentActivityProvider.allCases) { provider in providerSection(provider) }
            }
            Section("Terminal discovery and attention") {
                Toggle(
                    "Discover agents in local and remote Herdr terminals",
                    isOn: $discovery.configured(AppStorageKeys.Tabs.herdrEnabled))
                Toggle(
                    "Inspect blocked agents and stalled progress",
                    isOn: setting(\.monitorTerminalAttention)
                )
                .disabled(!discovery)
                Text(
                    "Terminal monitoring distinguishes approval prompts, questions, errors, and confirmed lack of progress. Quiet provider hooks are shown separately. Notification choices remain in Background agent settings."
                )
                .font(.edithText(.caption)).foregroundStyle(.secondary)
                Stepper(
                    "Check stalled progress after \(stuckMinutes) minutes",
                    value: $stuckMinutes.configured(AgentSettingsKeys.stuckMinutes), in: 2...120
                )
                .disabled(!discovery || !settings.monitorTerminalAttention)
                Stepper(
                    "Mark quiet hooks after \(settings.quietMinutes) minutes",
                    value: setting(\.quietMinutes), in: 2...120)
            }
            if !monitor.activity.approvals.isEmpty {
                Section("Pending permissions") {
                    ForEach(monitor.activity.approvals) { request in
                        AgentApprovalCard(request: request, monitor: monitor)
                    }
                }
            }
            Section("Surface widgets") {
                Text(
                    "Each agent widget has independent provider, state, subagent, field, and row controls."
                )
                .font(.edithText(.callout)).foregroundStyle(.secondary)
                HStack {
                    Button("Edit Home") { MainApp.openSurfaceEditor(.home) }
                    Button("Edit Notch") { MainApp.openSurfaceEditor(.notch) }
                }.buttonStyle(.edith(.secondary))
            }
        }
        .edithForm()
        .disabled(working)
        .pageTask { await monitor.observe() }
        .onReceive(DistributedNotificationCenter.default().publisher(for: IPC.Name.settingsChanged))
        { _ in settings = AgentActivitySettings.load() }
        .edithSheet(item: $preview) { item in
            VStack(alignment: .leading, spacing: UIScale.pt(14)) {
                Text(item.enabled ? "Configure \(item.plan.provider.title)" : "Remove Edith hooks")
                    .font(.edithText(.title2))
                Text(item.plan.url.path).font(.edithText(.caption)).textSelection(.enabled)
                Text(
                    "Existing policies and unrelated hooks are preserved. Edith saves a private backup before changing this file."
                )
                .font(.edithText(.callout)).foregroundStyle(.secondary)
                ScrollView {
                    Text(
                        String(
                            decoding: item.plan.replacement
                                ?? Data("Remove this integration's plugin file.".utf8),
                            as: UTF8.self)
                    )
                    .font(.edithText(.caption)).monospaced().textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Cancel") { preview = nil }.buttonStyle(.edith(.secondary))
                    Spacer()
                    Button(item.enabled ? "Write hooks" : "Remove from this scope") { apply(item) }
                        .buttonStyle(.edith(.primary)).disabled(working)
                }
            }
            .padding(UIScale.pt(20)).frame(
                minWidth: UIScale.pt(420), idealWidth: UIScale.pt(680), minHeight: UIScale.pt(400),
                idealHeight: UIScale.pt(560)
            )
            .interactiveDismissDisabled(working)
        }
    }

    private func providerSection(_ provider: AgentActivityProvider) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            HStack {
                Text(provider.title).font(.edithText(.headline))
                Spacer()
                Label(
                    status(provider),
                    systemImage: monitor.activity.providerSignals[provider.rawValue] == nil
                        ? "circle.dotted" : "checkmark.circle.fill"
                )
                .font(.edithText(.caption)).foregroundStyle(.secondary)
            }
            Toggle("Observe session activity", isOn: providerSetting(provider, \.observing))
            if provider.supportsPermissionApprovals {
                Toggle(
                    "Handle permission requests in Edith",
                    isOn: providerSetting(provider, \.approvals)
                )
                .disabled(!settings.configuration(provider).observing)
            } else {
                Text(
                    "Activity appears in Edith. Complete approvals in the provider."
                )
                .font(.edithText(.caption)).foregroundStyle(.secondary)
            }
            if settings.configuration(provider).approvals {
                Text(
                    "Requests wait up to two minutes for Allow once or Deny, then follow the provider's normal approval behavior."
                )
                .font(.edithText(.caption)).foregroundStyle(.secondary)
            }
            if provider == .codex {
                Text(
                    "Review and trust the exact hook commands in /hooks, then start or resume a session. Hook configuration alone does not enable a connection."
                )
                .font(.edithText(.caption)).foregroundStyle(.secondary)
            } else {
                Text(
                    "Start or resume a session after writing hooks. Provider policy and disabled-hook settings still apply."
                )
                .font(.edithText(.caption)).foregroundStyle(.secondary)
            }
            HStack {
                Button("Review hook setup") { prepare(provider, enabled: true) }
                Button("Remove hooks") { prepare(provider, enabled: false) }
            }.buttonStyle(.edith(.secondary)).disabled(projectScope && project == nil)
            if let signal = monitor.activity.providerSignals[provider.rawValue] {
                Text("Last event \(signal.formatted(.dateTime.month().day().hour().minute()))")
                    .font(.edithText(.caption)).foregroundStyle(.secondary)
            }
        }.padding(.vertical, UIScale.pt(8))
    }

    private func status(_ provider: AgentActivityProvider) -> String {
        guard settings.configuration(provider).observing else { return "Off" }
        guard let signal = monitor.activity.providerSignals[provider.rawValue] else {
            return "Awaiting event"
        }
        return monitor.now.timeIntervalSince(signal) < Double(settings.quietMinutes * 60)
            ? "Receiving events" : "No recent event"
    }

    private func providerSetting(
        _ provider: AgentActivityProvider,
        _ key: WritableKeyPath<AgentActivityProviderSettings, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { settings.configuration(provider)[keyPath: key] },
            set: { value in
                var next = settings
                var configuration = next.configuration(provider)
                configuration[keyPath: key] = value
                next.providers[provider.rawValue] = configuration
                save(next)
            })
    }

    private func setting<Value>(_ key: WritableKeyPath<AgentActivitySettings, Value>) -> Binding<
        Value
    > {
        Binding(
            get: { settings[keyPath: key] },
            set: { value in
                var next = settings
                next[keyPath: key] = value
                save(next)
            })
    }

    private func save(_ value: AgentActivitySettings) {
        do { try value.save(); settings = value.normalized(); error = nil } catch {
            self.error = error.localizedDescription
        }
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { project = panel.url }
    }

    private func prepare(_ provider: AgentActivityProvider, enabled: Bool) {
        let scope: AgentActivityHookScope
        if projectScope {
            guard let project else { error = "Choose a project folder first."; return }
            scope = .project(project)
        } else {
            scope = .global
        }
        working = true
        Task {
            defer { working = false }
            do {
                let installer = installer
                let plan = try await Task.detached {
                    try installer.plan(provider: provider, scope: scope, enabled: enabled)
                }.value
                preview = AgentHookPreview(plan: plan, enabled: enabled)
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    private func apply(_ item: AgentHookPreview) {
        working = true
        Task {
            defer { working = false }
            do {
                let installer = installer
                let installation = try await Task.detached { try installer.apply(item.plan) }.value
                if item.enabled {
                    var next = settings
                    var configuration = next.configuration(item.plan.provider)
                    configuration.observing = true
                    next.providers[item.plan.provider.rawValue] = configuration
                    try next.save()
                    settings = next.normalized()
                }
                result =
                    installation.changed
                    ? "Updated \(installation.url.path)" : "Hooks are already configured."
                if let backup = installation.backupURL {
                    result = (result ?? "") + "\nBackup: " + backup.path
                }
                preview = nil
                error = nil
            } catch { preview = nil; self.error = error.localizedDescription }
        }
    }
}
