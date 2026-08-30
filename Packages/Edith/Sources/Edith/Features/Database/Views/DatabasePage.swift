import AppKit
import EdithDatabase
import EdithKit
import Observation
import SwiftUI

@MainActor
@Observable
final class DatabasePageModel {
    enum Readiness: Equatable {
        case checking
        case ready
        case failed(String)
    }

    private(set) var readiness = Readiness.checking
    private let ensureReady: @Sendable () async throws -> Void
    private var generation = UUID()

    init(
        ensureReady: @escaping @Sendable () async throws -> Void = {
            try await DatabaseBrokerClientCoordinator.shared.ensureReady()
        }
    ) {
        self.ensureReady = ensureReady
    }

    var statusTitle: String {
        switch readiness {
        case .checking: "Checking broker"
        case .ready: "Broker ready"
        case .failed: "Broker unavailable"
        }
    }

    var statusSymbol: String {
        switch readiness {
        case .checking: "arrow.triangle.2.circlepath"
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var statusColor: Color {
        switch readiness {
        case .checking: .secondary
        case .ready: DashSkin.ok
        case .failed: DashSkin.warn
        }
    }

    var failureDetail: String? {
        guard case let .failed(detail) = readiness else { return nil }
        return detail
    }

    func refresh() async {
        let requestGeneration = UUID()
        generation = requestGeneration
        readiness = .checking
        do {
            try await ensureReady()
            guard generation == requestGeneration, !Task.isCancelled else { return }
            readiness = .ready
            announce("Database broker ready.")
        } catch is CancellationError {
        } catch {
            guard generation == requestGeneration, !Task.isCancelled else { return }
            readiness = .failed(Self.message(for: error))
            announce("Database broker unavailable.")
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
            return "The local database broker could not be reached."
        }
        switch availability {
        case .readinessTimedOut:
            return "The local database broker did not become ready in time."
        case .versionTransitionTimedOut:
            return "The local database broker could not finish updating."
        case .unsafePeer:
            return "The local database broker failed peer authentication."
        case .outcomeUnknown:
            return "The local database broker could not confirm its readiness outcome."
        case .unavailable:
            return "The local database broker is unavailable."
        }
    }
}

struct DatabasePage: View {
    @State private var model = DatabasePageModel()
    @State private var workspace = DatabaseWorkspaceModel()
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Database", trailing: { status })
            Divider().opacity(0.35)
            Group {
                if compact {
                    ScrollView { compactContent }
                } else {
                    HStack(spacing: 0) {
                        ScrollView {
                            connections
                                .frame(minHeight: UIScale.pt(360))
                        }
                        .frame(width: UIScale.pt(250))
                        Divider().opacity(0.35)
                        ScrollView { workbench }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DashSkin.paper(dark))
        .task {
            guard automaticActionsEnabled else { return }
            await model.refresh()
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
    }

    private var status: some View {
        Button {
            Task { await model.refresh() }
        } label: {
            HStack(spacing: UIScale.pt(6)) {
                Image(systemName: model.statusSymbol)
                    .foregroundStyle(model.statusColor)
                Text(model.statusTitle)
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            .font(.system(size: UIScale.pt(11.5), weight: .medium))
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .help("Check the local database broker")
    }

    private var compactContent: some View {
        VStack(spacing: UIScale.pt(16)) {
            connections
            workbench
        }
        .padding(UIScale.pt(18))
    }

    private var connections: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            Text("Connections")
                .font(.system(size: UIScale.pt(12), weight: .semibold))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer(minLength: UIScale.pt(12))
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: UIScale.pt(30), weight: .light))
                .foregroundStyle(DashSkin.inkFaint(dark).opacity(0.7))
            Text("No database connected")
                .font(.system(size: UIScale.pt(14), weight: .semibold))
            Text(
                "Connections stay behind the authenticated local broker and never expose credentials to the app process."
            )
            .font(.system(size: UIScale.pt(12)))
            .foregroundStyle(DashSkin.inkFaint(dark))
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: UIScale.pt(12))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(UIScale.pt(18))
        .background(DashSkin.paper2(dark).opacity(0.55))
    }

    private var workbench: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(18)) {
            Text("Safe database work starts here")
                .font(.system(size: UIScale.pt(24), weight: .semibold))
                .tracking(-0.5)
            Text(
                "Explore data with bounded reads, then preview every mutation before anything changes."
            )
            .font(.system(size: UIScale.pt(14)))
            .foregroundStyle(DashSkin.inkFaint(dark))
            .fixedSize(horizontal: false, vertical: true)
            if let detail = model.failureDetail {
                brokerFailure(detail)
            }
            if let notice = workspace.mutationNotice {
                mutationNotice(notice)
            }
            VStack(spacing: UIScale.pt(12)) {
                workbenchStep(
                    "1", "Connect through the broker",
                    "Credentials remain in the secret store while the broker owns database sessions."
                )
                workbenchStep(
                    "2", "Explore with bounded reads",
                    "Catalogs, schemas, collections, indexes and records load through paged operations."
                )
                workbenchStep(
                    "3", "Review before changing data",
                    "Destructive operations require an exact preview, fresh token and typed confirmation."
                )
            }
        }
        .frame(maxWidth: UIScale.pt(720), alignment: .leading)
        .padding(UIScale.pt(28))
    }

    private func brokerFailure(_ detail: String) -> some View {
        HStack(alignment: .top, spacing: UIScale.pt(10)) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DashSkin.warn)
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                Text("Broker unavailable")
                    .font(.system(size: UIScale.pt(13), weight: .semibold))
                Text(detail)
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UIScale.pt(14))
        .background(DashSkin.warn.opacity(0.1), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
    }

    private func mutationNotice(_ detail: String) -> some View {
        HStack(alignment: .top, spacing: UIScale.pt(10)) {
            Image(
                systemName: workspace.hasTrackedMutation
                    ? "clock.arrow.circlepath" : "info.circle.fill"
            )
            .foregroundStyle(
                workspace.hasTrackedMutation ? DashSkin.warn : DashSkin.accent(dark))
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                Text(
                    workspace.hasTrackedMutation ? "Mutation requires tracking" : "Mutation status"
                )
                .font(.system(size: UIScale.pt(13), weight: .semibold))
                Text(detail)
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .fixedSize(horizontal: false, vertical: true)
                if workspace.hasTrackedMutation {
                    HStack(spacing: UIScale.pt(8)) {
                        if workspace.safetyPhase.allowsOperationCancellation {
                            Button(
                                workspace.acceptedMutation == nil
                                    ? "Cancel operation" : "Cancel mutation"
                            ) {
                                workspace.cancelSafetyOperation()
                            }
                            .buttonStyle(.edith(.secondary))
                        }
                        if workspace.safetyPhase.allowsReconciliation {
                            Button("Check mutation status") {
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
                            .foregroundStyle(DashSkin.inkFaint(dark))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UIScale.pt(14))
        .background(DashSkin.warn.opacity(0.1), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
    }

    private func workbenchStep(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: UIScale.pt(12)) {
            Text(number)
                .font(.system(size: UIScale.pt(12), weight: .bold, design: .rounded))
                .frame(width: UIScale.pt(28), height: UIScale.pt(28))
                .foregroundStyle(DashSkin.accent(dark))
                .background(
                    DashSkin.accent(dark).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                Text(title)
                    .font(.system(size: UIScale.pt(14), weight: .semibold))
                Text(detail)
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(UIScale.pt(14))
        .background(
            DashSkin.paper2(dark),
            in: RoundedRectangle(cornerRadius: UIScale.pt(12))
        )
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(12))
                .stroke(DashSkin.line(dark), lineWidth: 1)
        }
    }
}
