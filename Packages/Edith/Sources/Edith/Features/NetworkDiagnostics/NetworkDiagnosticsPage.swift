import AppKit
import EdithKit
import Observation
import SwiftUI
import UserNotifications

@MainActor
@Observable
final class NetworkDiagnosticsModel {
    var configuration = NetworkDiagnosticsPreferences.configuration()
    var latest: NetworkDiagnosticSnapshot?
    var timeline: [NetworkDiagnosticSnapshot] = []
    var running = false
    var errorMessage: String?
    var settingsPresented = false
    var serviceText = ""
    var exclusionText = ""
    private var runTask: Task<Void, Never>?

    init() {
        serviceText = configuration.serviceTargets.map { "\($0.host):\($0.port)" }
            .joined(separator: ", ")
        exclusionText = configuration.exclusions.joined(separator: ", ")
    }

    func activate() {
        Task {
            timeline = await NetworkDiagnosticsTimelineStore.shared.load(
                limit: configuration.timelineLimit)
        }
    }

    func deactivate() {
        runTask?.cancel()
        runTask = nil
        running = false
    }

    func run() {
        guard runTask == nil else { return }
        running = true
        errorMessage = nil
        let config = configuration.normalized
        let baseline = NetworkDiagnosticsPreferences.baseline()
        runTask = Task {
            let snapshot = await NetworkDiagnosticsEngine().diagnose(
                configuration: config, baseline: baseline)
            guard !Task.isCancelled else {
                running = false
                runTask = nil
                return
            }
            await accept(snapshot, configuration: config)
            running = false
            runTask = nil
        }
    }

    func cancel() {
        runTask?.cancel()
    }

    func saveSettings() {
        configuration.serviceTargets = serviceText.split(separator: ",").compactMap { value in
            let parts = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = parts.lastIndex(of: ":"),
                let port = Int(parts[parts.index(after: separator)...]),
                (1...65535).contains(port)
            else { return nil }
            return NetworkServiceTarget(host: String(parts[..<separator]), port: port)
        }
        configuration.exclusions = exclusionText.split(separator: ",").map(String.init)
        configuration = configuration.normalized
        NetworkDiagnosticsPreferences.save(configuration)
        IPC.post(IPC.Name.settingsChanged)
        if configuration.notificationsEnabled {
            Task {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(
                    options: [.alert, .sound])
            }
        }
        settingsPresented = false
    }

    func saveBaseline() {
        guard let latest else { return }
        NetworkDiagnosticsPreferences.saveBaseline(latest)
        self.latest = latest.compared(with: latest)
    }

    func copyReport() {
        guard let latest else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            NetworkDiagnosticsRedactor.report(latest), forType: .string)
    }

    func exportReport() {
        guard let latest else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "network-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try NetworkDiagnosticsRedactor.report(latest).write(
                to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func accept(
        _ snapshot: NetworkDiagnosticSnapshot,
        configuration: NetworkDiagnosticsConfiguration
    ) async {
        let previous = latest ?? timeline.first
        latest = snapshot
        do {
            timeline = try await NetworkDiagnosticsTimelineStore.shared.append(
                snapshot, limit: configuration.timelineLimit)
        } catch {
            errorMessage = error.localizedDescription
        }
        if configuration.notificationsEnabled, previous?.state != snapshot.state,
            snapshot.state == .failed || previous?.state == .failed
        {
            let content = UNMutableNotificationContent()
            content.title = "Network state changed"
            content.body = "Diagnostics now report \(snapshot.state.rawValue)."
            content.sound = .default
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                    identifier: "network-diagnostics-state", content: content, trigger: nil))
        }
    }
}

struct NetworkDiagnosticsPage: View {
    @State private var model = NetworkDiagnosticsModel()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                    if let error = model.errorMessage { statusMessage(error) }
                    pathSummary
                    checks
                    baselineChanges
                    timeline
                }
                .pageContent(compact, width: .readable)
            }
        }
        .background(DashSkin.paper(dark))
        .sheet(isPresented: $model.settingsPresented) { settings }
        .onAppear { model.activate() }
        .onDisappear { model.deactivate() }
    }

    private var header: some View {
        PageHeader(
            "Network Diagnostics",
            trailing: {
                HStack(spacing: 8) {
                    Button {
                        model.settingsPresented = true
                    } label: {
                        Label("Targets", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.edith(.secondary))
                    Button {
                        model.running ? model.cancel() : model.run()
                    } label: {
                        Label(
                            model.running ? "Cancel" : "Run snapshot",
                            systemImage: model.running ? "xmark" : "waveform.path.ecg")
                    }
                    .buttonStyle(.edith(model.running ? .destructive : .primary))
                }
            })
    }

    private var pathSummary: some View {
        let snapshot = model.latest ?? model.timeline.first
        return SkinCard(title: "Current path", dark: dark) {
            if let snapshot {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: compact ? 150 : 190))], spacing: 12
                ) {
                    metric("Interface", snapshot.path.interfaceName ?? "Unavailable")
                    metric("Gateway", snapshot.path.gateway ?? "Unavailable")
                    metric("DNS resolvers", "\(snapshot.path.dnsServers.count)")
                    metric("Wi-Fi", snapshot.path.wifiName ?? "Metadata unavailable")
                    metric("Proxy", snapshot.path.proxyHint ?? "None detected")
                    metric("VPN", snapshot.path.vpnHint ?? "None detected")
                }
                HStack(spacing: 8) {
                    Label(snapshot.state.rawValue.capitalized, systemImage: symbol(snapshot.state))
                        .foregroundStyle(color(snapshot.state))
                    Text("\(Int(snapshot.durationMS)) ms total")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Save healthy baseline") { model.saveBaseline() }
                        .buttonStyle(.edith(.secondary))
                        .disabled(snapshot.state != .healthy)
                    Button("Copy report") { model.copyReport() }
                        .buttonStyle(.edith(.secondary))
                    Button("Export") { model.exportReport() }
                        .buttonStyle(.edith(.secondary))
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.top, 12)
            } else {
                ContentUnavailableView(
                    "Ready to diagnose", systemImage: "network",
                    description: Text("Local path checks run without changing network settings.")
                )
                .frame(maxWidth: .infinity, minHeight: 130)
            }
        }
    }

    private var checks: some View {
        SkinCard(title: "Explainable checks", dark: dark) {
            if let snapshot = model.latest ?? model.timeline.first {
                VStack(spacing: 0) {
                    ForEach(snapshot.checks) { check in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: symbol(check.state))
                                .foregroundStyle(color(check.state)).frame(width: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(check.title).font(.system(size: 13, weight: .semibold))
                                Text(check.summary).font(.system(size: 12)).foregroundStyle(
                                    .secondary)
                            }
                            Spacer()
                            if let duration = check.durationMS {
                                Text("\(Int(duration)) ms").monospacedDigit()
                            }
                            if let loss = check.packetLossPercent {
                                Text("\(String(format: "%.0f", loss))% loss").monospacedDigit()
                            }
                        }
                        .font(.system(size: 11))
                        .padding(.vertical, 9)
                        if check.id != snapshot.checks.last?.id { Divider().opacity(0.35) }
                    }
                }
            } else {
                Text("Configure explicit remote targets, or run local-only checks now.")
                    .foregroundStyle(.secondary).padding(.vertical, 20)
            }
        }
    }

    @ViewBuilder
    private var baselineChanges: some View {
        if let changes = model.latest?.baselineChanges, !changes.isEmpty {
            SkinCard(title: "Changed from baseline", dark: dark) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(changes, id: \.self) { change in
                        Label(change, systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .font(.system(size: 12))
            }
        }
    }

    private var timeline: some View {
        SkinCard(title: "Diagnostic timeline", dark: dark) {
            if model.timeline.isEmpty {
                Text("Snapshots appear here with bounded retention.")
                    .foregroundStyle(.secondary).padding(.vertical, 18)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.timeline.prefix(12)) { snapshot in
                        HStack(spacing: 9) {
                            Image(systemName: symbol(snapshot.state)).foregroundStyle(
                                color(snapshot.state))
                            Text(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))
                            Spacer()
                            Text(snapshot.state.rawValue.capitalized).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12))
                        .padding(.vertical, 7)
                    }
                }
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Network targets").font(.title2.weight(.semibold))
            Text("Only targets entered here are contacted. Empty fields stay local-only.")
                .font(.callout).foregroundStyle(.secondary)
            Group {
                TextField("Reachability host", text: $model.configuration.targetHost)
                TextField("DNS lookup name", text: $model.configuration.dnsName)
                TextField("HTTP URL", text: $model.configuration.httpTarget)
                TextField("HTTPS URL", text: $model.configuration.httpsTarget)
                TextField("Services, host:port separated by commas", text: $model.serviceText)
                TextField(
                    "Excluded hosts or suffixes, separated by commas", text: $model.exclusionText)
            }
            .textFieldStyle(.roundedBorder)
            Toggle("Allow public IP lookup", isOn: $model.configuration.publicIPEnabled)
            Toggle(
                "Enable low-energy scheduled snapshots",
                isOn: $model.configuration.scheduledSamplingEnabled)
            Toggle(
                "Notify on meaningful state changes",
                isOn: $model.configuration.notificationsEnabled)
            Stepper(
                "Sample every \(model.configuration.sampleIntervalMinutes) minutes",
                value: $model.configuration.sampleIntervalMinutes, in: 5...1440, step: 5
            )
            .disabled(!model.configuration.scheduledSamplingEnabled)
            HStack {
                Stepper(
                    "Timeout \(Int(model.configuration.timeoutSeconds))s",
                    value: $model.configuration.timeoutSeconds, in: 1...30)
                Stepper(
                    "Retries \(model.configuration.retries)",
                    value: $model.configuration.retries, in: 0...3)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.settingsPresented = false }
                    .buttonStyle(.edith(.secondary))
                Button("Save") { model.saveSettings() }
                    .buttonStyle(.edith(.primary))
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(
                .tertiary)
            Text(value).font(.system(size: 13, weight: .medium)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusMessage(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12)).foregroundStyle(.orange)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func symbol(_ state: NetworkDiagnosticState) -> String {
        switch state {
        case .healthy: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        case .skipped: "minus.circle.fill"
        }
    }

    private func color(_ state: NetworkDiagnosticState) -> Color {
        switch state {
        case .healthy: .green
        case .warning: .orange
        case .failed: .red
        case .skipped: .secondary
        }
    }
}
