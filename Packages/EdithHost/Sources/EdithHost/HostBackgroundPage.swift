import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import ServiceManagement
import SwiftUI

struct HostBackgroundPage: View {
    @Bindable var services: HostCoreServices
    private let presenter: (any HostExtensionContentPresenting)?
    @State private var model: HostBackgroundModel
    @State private var policy: HostBackgroundPolicyModel

    init(
        services: HostCoreServices, model: HostBackgroundModel? = nil,
        presenter: (any HostExtensionContentPresenting)? = nil,
        policy: HostBackgroundPolicyModel? = nil
    ) {
        self.services = services
        self.presenter = presenter
        _model = State(
            initialValue: model
                ?? HostBackgroundModel(environment: HostBackgroundSource.live(services)))
        _policy = State(
            initialValue: policy
                ?? HostBackgroundPolicyModel(environment: HostBackgroundSource.policy(services)))
    }

    var body: some View {
        HostBackgroundContent(
            status: HostBackgroundStatus(services: services), model: model, policy: policy,
            actions: HostBackgroundActions(
                restart: { Task { await services.restart() } },
                copyLogCommand: { services.copyLogCommand() },
                openLoginItems: { SMAppService.openSystemSettingsLoginItems() },
                cancelTask: { try await services.cancelTask($0) },
                openOwner: { page in
                    services.defaults.set(page, forKey: AppStorageKeys.General.mainWindowSection)
                }),
            extra: {
                if let presenter {
                    HostBackgroundNotificationSection(
                        marketplace: services.marketplace, presenter: presenter)
                }
            }
        )
        .pageTask(id: services.snapshot?.collectedAt, cancel: model.cancel) {
            await model.refresh()
        }
    }
}

struct HostBackgroundActions {
    var restart: () -> Void = {}
    var copyLogCommand: () -> Void = {}
    var openLoginItems: () -> Void = {}
    var cancelTask: (UUID) async throws -> Void = { _ in }
    var openOwner: (String) -> Void = { _ in }
}

struct HostBackgroundTask: Identifiable, Equatable {
    enum State: Equatable {
        case queued, running, stopping, finished, failed, cancelled, interrupted

        var title: String {
            switch self {
            case .queued: "Waiting to start"
            case .running: "Running"
            case .stopping: "Stopping"
            case .finished: "Finished"
            case .failed: "Failed"
            case .cancelled: "Stopped"
            case .interrupted: "Interrupted"
            }
        }
        init(_ phase: HostCoreTaskSnapshot.Phase) {
            self =
                switch phase {
                case .running: .running
                case .completed: .finished
                case .cancelled: .cancelled
                case .failed: .failed
                }
        }

        init(_ state: HostAgentTaskState) {
            self =
                switch state {
                case .queued: .queued
                case .running: .running
                case .cancelling: .stopping
                case .succeeded: .finished
                case .failed: .failed
                case .cancelled: .cancelled
                case .interrupted: .interrupted
                }
        }

        var active: Bool { [.queued, .running, .stopping].contains(self) }
        var attention: Bool { [.failed, .interrupted].contains(self) }
    }

    let id: UUID
    let title: String
    let activity: String?
    let state: State
    let operation: String?
    let submitted: Date
    let started: Date?
    let finished: Date?
    let failure: String?

    var cancellable: Bool { state == .queued || state == .running }

    func timing(now: Date) -> String {
        if let finished {
            return "Finished \(HostCompactDuration.text(now.timeIntervalSince(finished))) ago"
        }
        if let started {
            return "Started \(HostCompactDuration.text(now.timeIntervalSince(started))) ago"
        }
        return "Queued \(HostCompactDuration.text(now.timeIntervalSince(submitted))) ago"
    }

    static func ordered(_ tasks: [HostBackgroundTask]) -> [HostBackgroundTask] {
        tasks.sorted {
            if $0.state.active != $1.state.active { return $0.state.active }
            return $0.submitted > $1.submitted
        }
    }
}

struct HostBackgroundStatus: Equatable {
    enum Phase: Equatable { case starting, running, stopped, failed }

    var phase: Phase
    var registration: HostLoginItem.Registration = .enabled
    var startedAt: Date?
    var residentBytes: UInt64?
    var cpuPercent: Double = 0
    var build: String = "Development"
    var processIdentifier: Int32?
    var schemaVersion: Int?
    var failure: String?
    var panelFailure: String?
    var tasks: [HostBackgroundTask] = []

    var activeTasks: Int { tasks.filter(\.state.active).count }
}

extension HostBackgroundStatus {
    @MainActor init(services: HostCoreServices) {
        let snapshot = services.snapshot
        let phase: Phase =
            services.failure != nil
            ? .failed : services.starting ? .starting : snapshot == nil ? .stopped : .running
        let core = (snapshot?.tasks ?? []).map { task in
            HostBackgroundTask(
                id: task.id, title: task.title, activity: nil,
                state: HostBackgroundTask.State(task.phase),
                operation: nil, submitted: task.startedAt, started: task.startedAt,
                finished: task.finishedAt, failure: task.message)
        }
        let commands = (snapshot?.commandTasks ?? []).map { task in
            HostBackgroundTask(
                id: task.id, title: task.title, activity: task.lastActivity,
                state: HostBackgroundTask.State(task.state),
                operation: task.operation, submitted: task.submittedAt, started: task.startedAt,
                finished: task.finishedAt, failure: task.failure)
        }
        self.init(
            phase: phase, registration: HostLoginItem.registration,
            startedAt: snapshot?.startedAt, residentBytes: snapshot?.residentBytes,
            cpuPercent: services.cpuPercent,
            build: snapshot?.agent?.build
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "Development",
            processIdentifier: snapshot?.pid, schemaVersion: snapshot?.agent?.schemaVersion,
            failure: services.failure, panelFailure: services.panelFailure,
            tasks: HostBackgroundTask.ordered(core + commands))
    }
}

struct HostBackgroundContent<Extra: View>: View {
    let status: HostBackgroundStatus
    @Bindable var model: HostBackgroundModel
    @Bindable var policy: HostBackgroundPolicyModel
    var actions = HostBackgroundActions()
    var now: () -> Date = { Date() }
    @ViewBuilder var extra: () -> Extra
    @State private var showingEvents = false

    var body: some View {
        Form {
            HostBackgroundOverviewSection(
                status: status,
                overview: HostBackgroundOverview(
                    jobs: model.jobs, activeTasks: status.activeTasks),
                now: now(), actions: actions)
            HostBackgroundJobsSection(
                model: model, phase: status.phase, now: now(),
                destination: { owner in
                    HostNavigationCatalog.pages.first { $0.extensionID == owner }
                },
                open: actions.openOwner)
            HostBackgroundTasksSection(
                status: status, now: now(), cancel: actions.cancelTask)
            HostBackgroundPolicySection(model: policy)
            extra()
            HostBackgroundDiagnosticsSection(
                status: status, showingEvents: $showingEvents, actions: actions)
        }
        .edithForm()
        .edithSheet(isPresented: $showingEvents) {
            HostBackgroundEventTimeline(model: model)
        }
    }
}

extension HostBackgroundContent where Extra == EmptyView {
    init(
        status: HostBackgroundStatus, model: HostBackgroundModel,
        policy: HostBackgroundPolicyModel, actions: HostBackgroundActions = .init(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.init(
            status: status, model: model, policy: policy, actions: actions, now: now,
            extra: { EmptyView() })
    }
}
