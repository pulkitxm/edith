import EdithKit
import SwiftUI

struct WorkspaceRestorerRows: View {
    @AppStorage(AppStorageKeys.WorkspaceRestorer.enabled, store: SharedDefaults.store) private
        var enabled = false
    @AppStorage(
        AppStorageKeys.WorkspaceRestorer.launchPolicy, store: SharedDefaults.store)
    private var launchPolicy = WorkspaceLaunchPolicy.never.rawValue
    @AppStorage(AppStorageKeys.WorkspaceRestorer.timeout, store: SharedDefaults.store) private
        var timeout = 12.0
    @AppStorage(AppStorageKeys.WorkspaceRestorer.concurrency, store: SharedDefaults.store) private
        var concurrency = 1
    @AppStorage(
        AppStorageKeys.WorkspaceRestorer.excludedApps, store: SharedDefaults.store)
    private var excludedApps = ""
    @State private var library = WorkspaceRestorerStore.load()
    @State private var selectedProfile = ""
    @State private var name = ""
    @State private var status = ""
    @State private var running = false

    var body: some View {
        Group {
            Section("Profiles") {
                TextField("Profile name", text: $name)
                HStack {
                    Button("Capture") { request(.capture, profile: name) }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Picker("Saved profile", selection: $selectedProfile) {
                        Text("Choose a profile").tag("")
                        ForEach(library.profiles) { profile in
                            Text("\(profile.name) · \(profile.windows.count) windows")
                                .tag(profile.id.uuidString)
                        }
                    }
                }
                HStack {
                    Button("Dry run") { request(.preview, profile: selectedProfile) }
                    Button("Restore") { request(.restore, profile: selectedProfile) }
                        .buttonStyle(.borderedProminent)
                    Button("Cancel") { request(.cancel) }
                        .disabled(!running)
                    Button("Recover") { request(.recover) }
                        .disabled(library.recoveryProfile == nil)
                }
                .disabled(selectedProfile.isEmpty && !running)
                HStack {
                    Button("Rename") { rename() }
                    Button("Duplicate") { duplicate() }
                    Button("Delete", role: .destructive) { remove() }
                }
                .disabled(selectedProfile.isEmpty || name.isEmpty)
                if !status.isEmpty { Text(status).settingsCaption() }
                if let run = library.history.first {
                    Text(
                        "Last result: \(run.items.filter { $0.state == .restored }.count) restored, "
                            + "\(run.items.filter { $0.state == .failed }.count) failed"
                    )
                    .settingsCaption()
                }
            }

            Section("Restore behavior") {
                Picker("Launch missing apps", selection: $launchPolicy) {
                    Text("Never").tag(WorkspaceLaunchPolicy.never.rawValue)
                    Text("When needed").tag(WorkspaceLaunchPolicy.missing.rawValue)
                }
                Stepper("Timeout: \(Int(timeout)) seconds", value: $timeout, in: 1...120)
                Picker("Launch concurrency", selection: $concurrency) {
                    ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                }
                TextField("Excluded bundle identifiers", text: $excludedApps)
                Text(
                    "Separate exclusions with commas. "
                        + "Window mutation remains sequential for safety."
                )
                .settingsCaption()
            }

            Section("Shortcuts") {
                LabeledContent("Capture") {
                    HotKeyRecorderControl(
                        keyPrefix: "workspaceRestorerCaptureHotKey", defaultLabel: "⌃⌥⇧S")
                }
                LabeledContent("Restore latest") {
                    HotKeyRecorderControl(
                        keyPrefix: "workspaceRestorerRestoreHotKey", defaultLabel: "⌃⌥⇧W")
                }
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
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
            status = response.ok ? responseSummary(response) : response.error ?? "Operation failed."
            refresh()
        }
    }

    private func request(
        _ operation: WorkspaceRestorerOperation, profile: String? = nil
    ) {
        let options = WorkspaceRestoreOptions(
            launchPolicy: WorkspaceLaunchPolicy(rawValue: launchPolicy) ?? .never,
            timeout: timeout, concurrency: concurrency)
        let request = WorkspaceRestorerRequest(
            operation: operation, profile: profile, options: options)
        guard let payload = WorkspaceRestorerIPC.payload(request) else { return }
        running = operation != .cancel
        status = ""
        IPC.post(IPC.Name.requestWorkspaceRestorer, userInfo: payload)
    }

    private func refresh() {
        library = WorkspaceRestorerStore.load()
        if !selectedProfile.isEmpty,
            !library.profiles.contains(where: { $0.id.uuidString == selectedProfile })
        {
            selectedProfile = ""
        }
        if selectedProfile.isEmpty, let profile = library.profiles.first {
            selectedProfile = profile.id.uuidString
            name = profile.name
        }
    }

    private func rename() {
        do {
            var updated = library
            let profile = try updated.rename(selectedProfile, to: name)
            try WorkspaceRestorerStore.save(updated)
            selectedProfile = profile.id.uuidString
            status = "Renamed to \(profile.name)."
            refresh()
            IPC.post(IPC.Name.workspaceRestorerChanged)
        } catch { status = error.localizedDescription }
    }

    private func duplicate() {
        do {
            var updated = library
            let profile = try updated.duplicate(selectedProfile, as: name)
            try WorkspaceRestorerStore.save(updated)
            selectedProfile = profile.id.uuidString
            status = "Duplicated as \(profile.name)."
            refresh()
            IPC.post(IPC.Name.workspaceRestorerChanged)
        } catch { status = error.localizedDescription }
    }

    private func remove() {
        do {
            var updated = library
            try updated.remove(selectedProfile)
            try WorkspaceRestorerStore.save(updated)
            selectedProfile = ""
            status = "Profile deleted."
            refresh()
            IPC.post(IPC.Name.workspaceRestorerChanged)
        } catch { status = error.localizedDescription }
    }

    private func responseSummary(_ response: WorkspaceRestorerResponse) -> String {
        if let profile = response.profile, response.run == nil {
            return "Captured \(profile.windows.count) windows in \(profile.name)."
        }
        guard let run = response.run else { return "Operation completed." }
        if run.dryRun {
            return "Dry run ready for \(run.items.count) windows."
        }
        var restored = 0
        for item in run.items where item.state == .restored { restored += 1 }
        return "Restored \(restored) of \(run.items.count) windows."
    }
}
