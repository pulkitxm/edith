import EdithKit
import SwiftUI

struct WorkspaceRestorerPanelView: View {
    @State private var library = WorkspaceRestorerStore.load()
    @State private var name = ""
    @State private var status = ""
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("New profile name", text: $name)
                Button("Capture") { request(.capture, profile: name) }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if library.profiles.isEmpty {
                ContentUnavailableView(
                    "No workspace profiles", systemImage: "rectangle.3.group",
                    description: Text("Capture this desktop to restore it later."))
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(library.profiles) { profile in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name).font(.system(size: 12, weight: .medium))
                                    Text(
                                        "\(profile.windows.count) windows · \(profile.displays.count) displays"
                                    )
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Dry run") {
                                    request(.preview, profile: profile.id.uuidString)
                                }
                                .buttonStyle(.edith(.toolbar))
                                Button("Restore") {
                                    request(.restore, profile: profile.id.uuidString)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(8)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .frame(maxHeight: 250)
            }
            HStack {
                if running {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { request(.cancel) }
                }
                if library.recoveryProfile != nil {
                    Button("Recover previous layout") { request(.recover) }
                }
                Spacer()
                if !status.isEmpty {
                    Text(status).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { refresh() }
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: IPC.Name.workspaceRestorerChanged)
        ) { _ in
            refresh()
        }
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: IPC.Name.workspaceRestorerResult)
        ) { notification in
            guard
                let response = WorkspaceRestorerIPC.decode(
                    WorkspaceRestorerResponse.self, from: notification.userInfo ?? [:])
            else { return }
            running = false
            if let profile = response.profile, response.run == nil {
                status = "Captured \(profile.windows.count) windows"
            } else if let run = response.run {
                status = run.dryRun
                    ? "\(run.items.count) windows planned"
                    : "\(run.items.filter { $0.state == .restored }.count) restored"
            } else {
                status = response.error ?? "Done"
            }
            refresh()
        }
    }

    private func request(_ operation: WorkspaceRestorerOperation, profile: String? = nil) {
        let defaults = SharedDefaults.store
        let options = WorkspaceRestoreOptions(
            launchPolicy: WorkspaceLaunchPolicy(
                rawValue: defaults.string(
                    forKey: AppStorageKeys.WorkspaceRestorer.launchPolicy) ?? "") ?? .never,
            timeout: defaults.object(forKey: AppStorageKeys.WorkspaceRestorer.timeout) as? Double
                ?? 12,
            concurrency: defaults.object(
                forKey: AppStorageKeys.WorkspaceRestorer.concurrency) as? Int ?? 1)
        guard
            let payload = WorkspaceRestorerIPC.payload(
                WorkspaceRestorerRequest(
                    operation: operation, profile: profile, options: options))
        else { return }
        running = operation != .cancel
        status = ""
        IPC.post(IPC.Name.requestWorkspaceRestorer, userInfo: payload)
    }

    private func refresh() {
        library = WorkspaceRestorerStore.load()
    }
}
