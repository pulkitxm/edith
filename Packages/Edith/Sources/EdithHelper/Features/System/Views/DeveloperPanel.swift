import AppKit
import EdithKit
import SwiftUI

struct DeveloperPanel: View {
    let services: AppServices
    @State private var repoPath = SharedDefaults.store.string(forKey: Repo.pathKey) ?? ""
    @State private var diagnostics = AppInspectionCenter().diagnostics()
    @State private var refreshing = false
    private let inspection = AppInspectionCenter()

    private var versionLine: String {
        "v\(diagnostics.info.version) (\(diagnostics.info.build)) · up "
            + "\(diagnostics.uptimeText) · \(diagnostics.idleWakeups) idle wakeups"
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
                    Button("Data folder") { _ = try? inspection.openPath(.data) }
                    Button("Refresh log") { _ = try? inspection.openPath(.refreshLog) }
                    Button("Relaunch") { AppRuntimeCenter().relaunchCurrentApplication() }
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
            diagnostics = inspection.diagnostics()
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

}
