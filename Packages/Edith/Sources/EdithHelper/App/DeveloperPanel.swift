import AppKit
import Darwin
import EdithKit
import SwiftUI

enum ProcessUptime {
    static let launchedAt = Date()

    static var text: String {
        let seconds = Int(Date().timeIntervalSince(launchedAt))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

enum EnergyStats {
    static func idleWakeups() -> Int {
        var info = task_power_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_power_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.task_platform_idle_wakeups)
    }
}

struct DeveloperPanel: View {
    @EnvironmentObject private var services: AppServices
    @State private var repoPath = SharedDefaults.store.string(forKey: "repoPath") ?? ""
    @State private var idleWakeups = EnergyStats.idleWakeups()
    @State private var refreshing = false

    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "v\(version) (\(build)) · up \(ProcessUptime.text) · \(idleWakeups) idle wakeups"
    }

    var body: some View {
        DisclosureGroup("Developer") {
            VStack(alignment: .leading, spacing: 8) {
                Text(versionLine)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("Force refresh") {
                        refreshing = true
                        Task {
                            await services.usage?.refreshLimits(force: true)
                            refreshing = false
                        }
                    }
                    .disabled(refreshing || services.usage == nil)
                    Button("Data folder") { NSWorkspace.shared.open(Repo.dataDir) }
                    Button("Refresh log") { revealRefreshLog() }
                    Button("Relaunch") { relaunch() }
                }
                .buttonStyle(.link)
                .font(.system(size: 10))

                HStack(spacing: 6) {
                    TextField("Repo path override", text: $repoPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))
                        .onSubmit(saveRepoPath)
                    Button("Browse…", action: browseRepoPath)
                        .buttonStyle(.link)
                        .font(.system(size: 10))
                }
            }
            .padding(.top, 6)
        }
        .font(.system(size: 11))
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            idleWakeups = EnergyStats.idleWakeups()
        }
    }

    private func revealRefreshLog() {
        let log = Repo.dataDir.appendingPathComponent("refresh.log")
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.activateFileViewerSelecting([log])
        } else {
            NSWorkspace.shared.open(Repo.dataDir)
        }
    }

    private func saveRepoPath() {
        let trimmed = repoPath.trimmingCharacters(in: .whitespacesAndNewlines)
        Repo.setDevRootPath(trimmed.isEmpty ? nil : trimmed)
        IPC.post(IPC.Name.settingsChanged)
    }

    private func browseRepoPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        repoPath = url.path
        saveRepoPath()
    }

    private func relaunch() {
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        NSApp.terminate(nil)
    }
}
