import EdithKit
import SwiftUI

struct NetworkDiagnosticsPanel: View {
    let openWorkspace: () -> Void
    @State private var snapshot: NetworkDiagnosticSnapshot?
    @State private var running = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Network Diagnostics").font(.system(size: 15, weight: .semibold))
                    Text("Read-only, local-first checks").font(.system(size: 11)).foregroundStyle(
                        .secondary)
                }
                Spacer()
                Button("Open workspace", action: openWorkspace)
                    .buttonStyle(.edith(.toolbar))
            }
            if let snapshot {
                HStack(spacing: 9) {
                    Image(systemName: symbol(snapshot.state))
                        .foregroundStyle(color(snapshot.state))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.state.rawValue.capitalized)
                            .font(.system(size: 13, weight: .semibold))
                        Text("\(snapshot.checks.count) checks in \(Int(snapshot.durationMS)) ms")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(snapshot.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            } else {
                Text(
                    "Run a snapshot to inspect your current route, DNS, gateway, and configured targets."
                )
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            }
            Button {
                running ? task?.cancel() : run()
            } label: {
                Label(
                    running ? "Cancel" : "Run snapshot", systemImage: running ? "xmark" : "network"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.edith(running ? .destructive : .primary))
        }
        .onDisappear {
            task?.cancel()
            task = nil
            running = false
        }
    }

    private func run() {
        running = true
        let configuration = NetworkDiagnosticsPreferences.configuration()
        task = Task {
            let result = await NetworkDiagnosticsEngine().diagnose(
                configuration: configuration, baseline: NetworkDiagnosticsPreferences.baseline())
            guard !Task.isCancelled else { return }
            snapshot = result
            _ = try? await NetworkDiagnosticsTimelineStore.shared.append(
                result, limit: configuration.timelineLimit)
            running = false
            task = nil
        }
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
