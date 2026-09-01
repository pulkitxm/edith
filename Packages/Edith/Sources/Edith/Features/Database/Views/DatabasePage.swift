import AppKit
import EdithDatabase
import EdithKit
import Observation
import SwiftUI

@MainActor
@Observable
final class DatabasePageModel {
    enum Readiness: Hashable {
        case checking
        case repairing
        case ready
        case failed(String)
    }

    private(set) var readiness = Readiness.checking
    private let ensureReady: @Sendable () async throws -> Void
    private let repairService: @Sendable () async throws -> Void
    private var generation = UUID()

    init(
        ensureReady: @escaping @Sendable () async throws -> Void = {
            try await DatabaseBrokerClientCoordinator.shared.ensureReady()
        },
        repairService: @escaping @Sendable () async throws -> Void = {
            try await DatabaseBrokerServiceRepairer().repair()
            try await DatabaseBrokerClientCoordinator.shared.ensureReady()
        }
    ) {
        self.ensureReady = ensureReady
        self.repairService = repairService
    }

    var failureDetail: String? {
        guard case let .failed(detail) = readiness else { return nil }
        return detail
    }

    func refresh() async {
        await run(.checking, operation: ensureReady)
    }

    func repair() async {
        await run(.repairing, operation: repairService)
    }

    private func run(
        _ pendingState: Readiness,
        operation: @Sendable () async throws -> Void
    ) async {
        let requestGeneration = UUID()
        generation = requestGeneration
        readiness = pendingState
        do {
            try await operation()
            guard generation == requestGeneration, !Task.isCancelled else { return }
            readiness = .ready
            announce("Database tools are ready.")
        } catch is CancellationError {
        } catch {
            guard generation == requestGeneration, !Task.isCancelled else { return }
            readiness = .failed(Self.message(for: error))
            announce("Database tools need attention.")
        }
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
    }

    private static func message(for error: Error) -> String {
        guard let availability = error as? DatabaseBrokerAvailabilityError else {
            return "The local database service could not be reached."
        }
        switch availability {
        case .readinessTimedOut:
            return "The local database service did not become ready in time."
        case .versionTransitionTimedOut:
            return "The local database service could not finish updating."
        case .unsafePeer:
            return "The local database service could not be verified."
        case .outcomeUnknown:
            return "The local database service could not confirm its readiness."
        case .unavailable:
            return "The local database service is unavailable."
        }
    }
}

struct DatabasePage: View {
    @State private var model = DatabasePageModel()
    @State private var connectionWorkspace = DatabaseConnectionWorkspaceModel()
    @State private var connectionCreation: DatabaseConnectionCreationModel?
    @State private var dataWorkspace = DatabaseDataWorkspaceModel()
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

    private var dark: Bool { scheme == .dark }
    private var palette: DatabaseThemePalette {
        DatabaseThemePalette(dark: dark, theme: AppTheme(storedName: themeName))
    }
    private var theme: Color { palette.accent }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Database")
            Divider().opacity(0.35)
            pageContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.canvas)
        .environment(\.databaseAppTheme, palette.theme)
        .task {
            guard automaticActionsEnabled else { return }
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
            dataWorkspace.finishMutation(connection)
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
                },
                cancel: { self.connectionCreation = nil })
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch model.readiness {
        case .checking:
            serviceProgress(
                title: "Preparing Database",
                detail: "Starting the local tools used by your connections.")
        case .repairing:
            serviceProgress(
                title: "Repairing Database",
                detail: "Refreshing the local tools, then reopening your connections.")
        case .failed(let detail):
            serviceRecovery(detail)
        case .ready:
            readyContent
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        if let focusedConnectionID,
            let connection = connectionWorkspace.selectedConnection,
            connection.id == focusedConnectionID
        {
            focusedContent(connection)
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
            })
    }

    @ViewBuilder
    private func focusedContent(_ connection: DatabaseConnectionSummary) -> some View {
        if compact {
            focusedWorkspace(connection)
                .environment(\.compactLayout, true)
        } else {
            ViewThatFits(in: .horizontal) {
                focusedWorkspace(connection)
                    .environment(\.compactLayout, false)
                    .frame(minWidth: UIScale.pt(680))
                focusedWorkspace(connection)
                    .environment(\.compactLayout, true)
            }
        }
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
                back: leaveFocusedWorkspace)
            Divider().opacity(0.35)
            workbench
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func serviceProgress(title: String, detail: String) -> some View {
        VStack(spacing: UIScale.pt(14)) {
            ProgressView()
                .controlSize(.regular)
            Text(title)
                .font(.system(size: UIScale.pt(17), weight: .semibold))
            Text(detail)
                .font(.system(size: UIScale.pt(12.5)))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }

    private func serviceRecovery(_ detail: String) -> some View {
        VStack(spacing: UIScale.pt(18)) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.system(size: UIScale.pt(34), weight: .medium))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(spacing: UIScale.pt(7)) {
                Text("Database needs a quick repair")
                    .font(.system(size: UIScale.pt(20), weight: .semibold))
                Text(
                    "Edith can repair its local database tools and reopen your saved connections."
                )
                .font(.system(size: UIScale.pt(13)))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            Button("Repair and continue") {
                Task { await model.repair() }
            }
            .buttonStyle(.edith(.primary, tint: theme))
            DisclosureGroup("Technical details", isExpanded: $showsServiceDetails) {
                Text(detail)
                    .font(.system(size: UIScale.pt(11), design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, UIScale.pt(8))
            }
            .font(.system(size: UIScale.pt(11.5)))
            .frame(maxWidth: UIScale.pt(420))
        }
        .frame(maxWidth: UIScale.pt(560))
        .padding(UIScale.pt(36))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func beginConnectionCreation() {
        connectionCreation = DatabaseConnectionCreationModel()
    }

    private func openConnection(_ connection: DatabaseConnectionSummary) {
        connectionWorkspace.selectConnection(connection.id)
        catalogFocusConnectionID = connection.id
        workspaceFocusConnectionID = connection.id
        focusedConnectionID = connection.id
    }

    private func leaveFocusedWorkspace() {
        guard !workspace.hasTrackedMutation else { return }
        focusedConnectionID = nil
    }

    private func requestConnectionReload() {
        connectionListRevision &+= 1
    }

    private var connectionListTaskID: DatabaseConnectionListTaskID {
        DatabaseConnectionListTaskID(
            readiness: model.readiness,
            searchText: connectionWorkspace.searchText,
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
                data: dataWorkspace,
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
            .foregroundStyle(workspace.hasTrackedMutation ? Color.orange : theme)
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
                            ProgressView()
                                .controlSize(.small)
                            Text(
                                workspace.safetyPhase == .cancelling
                                    ? "Cancelling" : "Checking status"
                            )
                            .font(.system(size: UIScale.pt(11.5), weight: .medium))
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UIScale.pt(14))
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
    }

}

private struct DatabaseConnectionListTaskID: Hashable {
    let readiness: DatabasePageModel.Readiness
    let searchText: String
    let revision: UInt
}
