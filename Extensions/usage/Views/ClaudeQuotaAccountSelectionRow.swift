import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct ClaudeQuotaAccountSelectionRow: View {
    @Environment(\.usageUIClient) private var client
    @AppStorage(MenuBarLimits.accountSelectionKey, store: SharedDefaults.store) private
        var selectedID = ""
    @State private var accounts: [ClaudeAccountLimits] = []

    var body: some View {
        Group {
            if !accounts.isEmpty {
                Picker("Menu bar account", selection: $selectedID) {
                    Text("First account").tag("")
                    ForEach(accounts) { Text($0.name).tag($0.id.uuidString) }
                }
                .presenterCover(UsagePresenterState.shared.hides("Usage"))
            }
        }
        .pageTask {
            await reload()
            for await _ in NotificationCenter.default.notifications(
                named: UsageEvents.limitsUpdated)
            {
                guard !Task.isCancelled else { return }
                await reload()
            }
        }
        .onChange(of: selectedID) {
            if client == nil { UsageWorkerOperations.controller?.settingsChanged() }
        }
    }

    private func reload() async {
        let values: [ClaudeAccountLimits]
        if let client {
            values =
                (try? await client.value("usage.ui.limits.latest", as: UsageUILimitsSummary.self))?
                .current?.claudeAccounts ?? []
        } else {
            values = UsageWorkerOperations.controller?.latestLimits?.claudeAccounts ?? []
        }
        guard !Task.isCancelled else { return }
        accounts = values
    }
}
