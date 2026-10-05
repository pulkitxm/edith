import AppKit
import EdithDatabase
import EdithKit
import SwiftUI

@MainActor
struct DatabasePage: View {
    @State private var model: DatabasePageModel
    @State private var connectionWorkspace: DatabaseConnectionWorkspaceModel
    @State private var connectionManagement = DatabaseConnectionManagementModel()
    @State private var connectionCreation: DatabaseConnectionCreationModel?
    @State private var connectionManagementRoute: DatabaseConnectionManagementRoute?
    @State private var actionConfirmation: DatabaseConnectionActionConfirmation?
    @State private var managementMessage: DatabaseConnectionManagementMessage?
    @State private var tableTabs = DatabaseTableTabsModel()
    @State private var objectExplorer = DatabaseObjectExplorerModel()
    @State private var workspace = DatabaseWorkspaceModel()
    @State private var showsServiceDetails = false
    @State private var focusedConnectionID: DatabaseConnectionID?
    @State private var catalogFocusConnectionID: DatabaseConnectionID?
    @State private var workspaceFocusConnectionID: DatabaseConnectionID?
    @State private var connectionListRevision: UInt = 0
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        AppTheme.accent.rawValue
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme

    init(
        model: DatabasePageModel? = nil,
        connectionWorkspace: DatabaseConnectionWorkspaceModel? = nil
    ) {
        _model = State(initialValue: model ?? DatabasePageModel())
        _connectionWorkspace = State(
            initialValue: connectionWorkspace ?? DatabaseConnectionWorkspaceModel())
    }

    private var dark: Bool { scheme == .dark }
    private var connectionBinding: Binding<String> {
        Binding(
            get: { connectionWorkspace.selectedConnectionID?.rawValue.uuidString ?? "" },
            set: { raw in
                guard let id = UUID(uuidString: raw) else { return }
                connectionWorkspace.selectConnection(DatabaseConnectionID(rawValue: id))
            })
    }

    private func connectionIsValid(_ raw: String) -> Bool {
        guard let id = UUID(uuidString: raw) else { return false }
        return connectionWorkspace.listState.connections.contains { $0.id.rawValue == id }
    }
    private var palette: DatabaseThemePalette {
        DatabaseThemePalette(dark: dark, theme: AppTheme(storedName: themeName))
    }
    private var theme: Color { palette.accent }

    var body: some View {
        PageWorkspace {
            if model.readiness != .ready {
                PageHeader("Database")
                Divider().opacity(0.35)
            }
        } content: {
            pageContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.canvas)
        .navigationRoute(
            "connection", selection: connectionBinding, isValid: connectionIsValid,
            isReady: {
                if model.failureDetail != nil { return true }
                switch connectionWorkspace.listState {
                case .idle, .loading: return false
                default: return true
                }
            }()
        )
        .environment(\.databaseAppTheme, palette.theme)
        .pageTask {
            await model.refresh()
        }
        .task(id: connectionListTaskID) {
            guard automaticActionsEnabled, model.readiness == .ready else { return }
            let search = connectionWorkspace.searchText.trimmingCharacters(
                in: .whitespacesAndNewlines)
            if !search.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            await connectionWorkspace.loadConnections()
        }
        .onChange(of: workspace.safetyPhase) { _, phase in
            guard case .succeeded = phase,
                let connection = connectionWorkspace.selectedConnection
            else { return }
            tableTabs.finishMutation(target: workspace.mutationTarget, connection: connection)
        }
        .onChange(of: connectionWorkspace.selectedConnectionID) { _, connectionID in
            guard let focusedConnectionID, focusedConnectionID != connectionID else { return }
            self.focusedConnectionID = nil
        }
        .sheet(
            item: Binding(
                get: { workspace.safetyReview },
                set: { review in
                    if review == nil {
                        workspace.dismissSafetyReview()
                    }
                })
        ) { session in
            let current = workspace.safetyReview ?? session
            DatabaseSafetyReviewSheet(
                preview: current.preview,
                phase: workspace.safetyPhase,
                refreshPreview: { await workspace.refreshSafetyPreview() },
                reconcile: { await workspace.reconcileSafetyOperation() },
                confirm: { workspace.confirmSafetyReview($0) },
                cancelOperation: { workspace.cancelSafetyOperation() },
                dismiss: { workspace.dismissSafetyReview() })
        }
        .sheet(item: $connectionCreation) { connectionCreation in
            DatabaseConnectionCreationSheet(
                model: connectionCreation,
                saved: { connection in
                    self.connectionCreation = nil
                    connectionWorkspace.selectSavedConnection(connection)
                    connectionWorkspace.searchText = ""
                    catalogFocusConnectionID = connection.id
                    workspaceFocusConnectionID = connection.id
                    focusedConnectionID = connection.id
                    connectionListRevision &+= 1
                    Task { await connectionWorkspace.connectSelected() }
                },
                cancel: { self.connectionCreation = nil })
        }
        .sheet(item: $connectionManagementRoute) { route in
            DatabaseConnectionManagementSheet(
                connection: route.connection,
                model: connectionManagement,
                presentation: route.presentation,
                edited: finishManagedUpdate,
                renamed: finishManagedUpdate,
                duplicated: finishDuplicate,
                uncertain: beginUncertainManagementReconciliation,
                cancel: dismissConnectionManagement)
        }
        .confirmationDialog(
            connectionConfirmationTitle,
            isPresented: Binding(
                get: { actionConfirmation != nil },
                set: { presented in
                    if !presented {
                        actionConfirmation = nil
                    }
                }),
            titleVisibility: .visible
        ) {
            if let confirmation = actionConfirmation {
                switch confirmation {
                case .favorite(let connection):
                    Button(connection.isFavorite ? "Remove from favorites" : "Add to favorites") {
                        actionConfirmation = nil
                        Task { await toggleFavorite(connection) }
                    }
                case .delete(let connection):
                    Button("Delete saved connection", role: .destructive) {
                        actionConfirmation = nil
                        Task { await deleteConnection(connection) }
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                actionConfirmation = nil
            }
        } message: {
            Text(actionConfirmation?.detail ?? "")
        }
        .alert(item: $managementMessage) { message in
            Alert(
                title: Text(message.title),
                message: Text(message.detail),
                dismissButton: .default(Text("OK")))
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch model.readiness {
        case .checking:
            DatabaseServiceProgressView(
                title: "Preparing Database",
                detail: "Starting the local tools used by your connections.",
                compact: compact,
                palette: palette,
                theme: theme)
        case .installing(let fraction):
            DatabaseServiceProgressView(
                title: "Downloading Database",
                detail: "Downloading the signed database pack for this version.",
                fraction: fraction,
                compact: compact,
                palette: palette,
                theme: theme)
        case .repairing:
            DatabaseServiceProgressView(
                title: "Repairing Database",
                detail: "Refreshing the local tools, then reopening your connections.",
                compact: compact,
                palette: palette,
                theme: theme)
        case .failed(let detail):
            DatabaseServiceRecoveryView(
                detail: detail,
                theme: theme,
                showsDetails: $showsServiceDetails,
                repair: { Task { await model.repair() } })
        case .ready:
            readyContent.presenterCover(.database)
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        if let focusedConnectionID,
            let connection = connectionWorkspace.selectedConnection,
            connection.id == focusedConnectionID
        {
            focusedWorkspace(connection)
        } else {
            connectionCatalog
        }
    }

    private var connectionCatalog: some View {
        DatabaseConnectionGallery(
            model: connectionWorkspace,
            createConnection: beginConnectionCreation,
            openConnection: openConnection,
            reloadConnections: requestConnectionReload,
            restoreFocusConnectionID: catalogFocusConnectionID,
            focusRestored: { connectionID in
                guard catalogFocusConnectionID == connectionID else { return }
                catalogFocusConnectionID = nil
            },
            busyConnectionID: connectionManagement.activeConnectionID,
            performConnectionAction: performConnectionAction)
    }

    private func focusedWorkspace(_ connection: DatabaseConnectionSummary) -> some View {
        VStack(spacing: 0) {
            DatabaseFocusedConnectionHeader(
                connection: connection,
                sessionState: connectionWorkspace.selectedSessionState,
                backDisabled: workspace.hasTrackedMutation,
                focusRequested: workspaceFocusConnectionID == connection.id,
                focusCompleted: {
                    guard workspaceFocusConnectionID == connection.id else { return }
                    workspaceFocusConnectionID = nil
                },
                back: leaveFocusedWorkspace,
                busyConnectionID: connectionManagement.activeConnectionID,
                performConnectionAction: performConnectionAction)
            Divider().opacity(0.35)
            workbench
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func beginConnectionCreation() {
        connectionCreation = DatabaseConnectionCreationModel()
    }

    private func openConnection(_ connection: DatabaseConnectionSummary) {
        connectionWorkspace.selectConnection(connection.id)
        catalogFocusConnectionID = connection.id
        workspaceFocusConnectionID = connection.id
        focusedConnectionID = connection.id
        Task { await connectionWorkspace.connectSelected() }
    }

    private func leaveFocusedWorkspace() {
        guard !workspace.hasTrackedMutation else { return }
        focusedConnectionID = nil
    }

    private func requestConnectionReload() {
        connectionListRevision &+= 1
    }

    private func performConnectionAction(
        _ action: DatabaseConnectionCardAction,
        connection: DatabaseConnectionSummary
    ) {
        if workspace.hasTrackedMutation,
            connectionWorkspace.selectedConnectionID == connection.id
        {
            managementMessage = DatabaseConnectionManagementMessage(
                title: "Finish the active change first",
                detail:
                    "Resolve or cancel the current database change before managing this connection."
            )
            return
        }
        switch action {
        case .favorite:
            if case .disconnected = connectionWorkspace.sessionState(for: connection.id) {
                Task { await toggleFavorite(connection) }
            } else {
                actionConfirmation = .favorite(connection)
            }
        case .rename:
            presentConnectionManagement(.rename, connection: connection)
        case .edit:
            presentConnectionManagement(.edit, connection: connection)
        case .duplicate:
            presentConnectionManagement(.duplicate, connection: connection)
        case .delete:
            actionConfirmation = .delete(connection)
        }
    }

    private func presentConnectionManagement(
        _ presentation: DatabaseConnectionManagementPresentation,
        connection: DatabaseConnectionSummary
    ) {
        connectionManagement.clearFailure()
        connectionManagementRoute = DatabaseConnectionManagementRoute(
            presentation: presentation,
            connection: connection)
    }

    private func dismissConnectionManagement() {
        connectionManagement.clearFailure()
        connectionManagementRoute = nil
    }

    private func finishManagedUpdate(_ connection: DatabaseConnectionDefinition) {
        connectionManagementRoute = nil
        clearWorkspaceDataIfSelected(connection.id)
        connectionWorkspace.applyManagedConnection(connection, disconnectsSession: true)
        connectionListRevision &+= 1
    }

    private func finishDuplicate(_ result: DatabaseConnectionDuplicateResult) {
        connectionManagementRoute = nil
        connectionWorkspace.applyDuplicatedConnection(result.connection)
        focusedConnectionID = nil
        catalogFocusConnectionID = result.connection.id
        connectionListRevision &+= 1
        if result.sharesCredentials {
            managementMessage = DatabaseConnectionManagementMessage(
                title: "Connection duplicated",
                detail:
                    "The copy uses the same saved credential references as the original connection."
            )
        }
    }

    private func toggleFavorite(_ connection: DatabaseConnectionSummary) async {
        if let updated = await connectionManagement.toggleFavorite(connectionID: connection.id) {
            clearWorkspaceDataIfSelected(connection.id)
            connectionWorkspace.applyManagedConnection(updated, disconnectsSession: true)
            connectionListRevision &+= 1
        } else if let outcome = connectionManagement.uncertainOutcome {
            beginUncertainManagementReconciliation(outcome)
        } else {
            showManagementFailure()
        }
    }

    private func deleteConnection(_ connection: DatabaseConnectionSummary) async {
        guard let result = await connectionManagement.deleteConnection(connectionID: connection.id)
        else {
            if let outcome = connectionManagement.uncertainOutcome {
                beginUncertainManagementReconciliation(outcome)
            } else {
                showManagementFailure()
            }
            return
        }
        clearWorkspaceDataIfSelected(connection.id)
        let nextFocus = connectionWorkspace.removeManagedConnection(connection.id)
        if focusedConnectionID == connection.id {
            focusedConnectionID = nil
            workspaceFocusConnectionID = nil
        }
        catalogFocusConnectionID = nextFocus
        connectionListRevision &+= 1
        if !result.deleted {
            managementMessage = DatabaseConnectionManagementMessage(
                title: "Connection already removed",
                detail: "The saved connection was already absent, so its stale card was cleared."
            )
        }
    }

    private func beginUncertainManagementReconciliation(
        _ outcome: DatabaseConnectionManagementUncertainOutcome
    ) {
        connectionManagementRoute = nil
        focusedConnectionID = nil
        workspaceFocusConnectionID = nil
        connectionWorkspace.clearFilters()
        if outcome.mayDisconnectSession {
            clearWorkspaceDataIfSelected(outcome.connectionID)
            connectionWorkspace.invalidateManagedConnectionSession(outcome.connectionID)
        }
        connectionManagement.clearFailure()
        Task {
            await connectionWorkspace.loadConnections()
            catalogFocusConnectionID = connectionWorkspace.selectedConnectionID
            managementMessage = DatabaseConnectionManagementMessage(
                title: "Connection outcome needs review",
                detail: outcome.reconciliationDetail)
        }
    }

    private func clearWorkspaceDataIfSelected(_ connectionID: DatabaseConnectionID) {
        guard connectionWorkspace.selectedConnectionID == connectionID else { return }
        tableTabs.prepare(for: nil)
        objectExplorer.prepare(for: nil)
    }

    private func showManagementFailure() {
        managementMessage = DatabaseConnectionManagementMessage(
            title: "Connection change failed",
            detail: connectionManagement.failure ?? "The saved connection could not be changed."
        )
    }

    private var connectionConfirmationTitle: String {
        guard let confirmation = actionConfirmation else {
            return "Confirm connection change"
        }
        guard PresenterState.shared.hides(.database) else { return confirmation.title }
        switch confirmation {
        case .favorite(let connection):
            return connection.isFavorite
                ? "Remove this connection from favorites?"
                : "Add this connection to favorites?"
        case .delete:
            return "Delete this connection?"
        }
    }

    private var connectionListTaskID: DatabaseConnectionListTaskID {
        DatabaseConnectionListTaskID(
            readiness: model.readiness,
            searchText: connectionWorkspace.searchText,
            favoritesOnly: connectionWorkspace.favoritesOnly,
            selectedGroup: connectionWorkspace.selectedGroup,
            revision: connectionListRevision)
    }

    private var workbench: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let notice = workspace.mutationNotice {
                mutationNotice(notice)
                    .padding(.horizontal, UIScale.pt(28))
                    .padding(.top, UIScale.pt(18))
            }
            DatabaseWorkbenchView(
                connections: connectionWorkspace,
                explorer: objectExplorer,
                tabs: tableTabs,
                mutations: workspace)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func mutationNotice(_ detail: String) -> some View {
        HStack(alignment: .top, spacing: UIScale.pt(10)) {
            Image(
                systemName: workspace.hasTrackedMutation
                    ? "clock.arrow.circlepath" : "info.circle.fill"
            )
            .foregroundStyle(workspace.hasTrackedMutation ? DashSkin.warn : theme)
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                Text(
                    workspace.hasTrackedMutation ? "Change needs attention" : "Change status"
                )
                .font(.system(size: UIScale.pt(13), weight: .semibold))
                Text(detail)
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if workspace.hasTrackedMutation {
                    HStack(spacing: UIScale.pt(8)) {
                        if workspace.safetyPhase.allowsOperationCancellation {
                            Button(
                                "Cancel change"
                            ) {
                                workspace.cancelSafetyOperation()
                            }
                            .buttonStyle(.edith(.secondary))
                        }
                        if workspace.safetyPhase.allowsReconciliation {
                            Button("Check status") {
                                Task { await workspace.reconcileSafetyOperation() }
                            }
                            .buttonStyle(.edith(.secondary))
                        } else if workspace.safetyPhase == .cancelling
                            || workspace.safetyPhase == .reconciling
                        {
                            SkeletonReplica(
                                workspace.safetyPhase == .cancelling
                                    ? "Cancelling database change"
                                    : "Checking database change status"
                            ) {
                                Button(
                                    workspace.safetyPhase == .cancelling
                                        ? "Cancel change" : "Check status"
                                ) {}
                                .buttonStyle(.edith(.secondary))
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UIScale.pt(14))
        .background(DashSkin.warn.opacity(0.1), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
    }

}

private struct DatabaseConnectionListTaskID: Hashable {
    let readiness: DatabasePageModel.Readiness
    let searchText: String
    let favoritesOnly: Bool
    let selectedGroup: String?
    let revision: UInt
}

private struct DatabaseConnectionManagementRoute: Identifiable {
    let id = UUID()
    let presentation: DatabaseConnectionManagementPresentation
    let connection: DatabaseConnectionSummary
}

private struct DatabaseConnectionManagementMessage: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
}

private enum DatabaseConnectionActionConfirmation: Identifiable {
    case favorite(DatabaseConnectionSummary)
    case delete(DatabaseConnectionSummary)

    var id: String {
        switch self {
        case .favorite(let connection): "favorite:\(connection.id.rawValue.uuidString)"
        case .delete(let connection): "delete:\(connection.id.rawValue.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .favorite(let connection):
            connection.isFavorite
                ? "Remove \(connection.name) from favorites?"
                : "Add \(connection.name) to favorites?"
        case .delete(let connection):
            "Delete \(connection.name)?"
        }
    }

    var detail: String {
        switch self {
        case .favorite:
            "Updating this favorite closes its active session. You can reconnect from the workspace."
        case .delete:
            "This removes the saved connection and may close its active session. The database and its data are not changed."
        }
    }
}

private extension DatabaseConnectionManagementUncertainOutcome {
    var reconciliationDetail: String {
        switch operation {
        case .savingEdit:
            "The changes may have been saved. Review this connection before trying again."
        case .renaming:
            "The connection may have been renamed. Review the list before trying again."
        case .duplicating:
            "The copy may have been created. Review the list before trying again."
        case .togglingFavorite:
            "The favorite may have changed. Review the card before trying again."
        case .deleting:
            "The connection may have been removed. Review the list before trying again."
        case .loadingEdit:
            "The connection could not be reloaded. Review the saved connections before trying again."
        }
    }
}
