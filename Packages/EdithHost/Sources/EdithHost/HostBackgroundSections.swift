import AppKit
import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostBackgroundPolicySection: View {
    @Bindable var model: HostBackgroundPolicyModel

    private var failedOwners: [HostAmbientPolicyReceipt.Owner] {
        model.propagation?.owners.filter { !$0.applied } ?? []
    }

    var body: some View {
        Section("Battery") {
            if let value = model.value {
                Toggle(
                    "Pause scheduled jobs on battery",
                    isOn: Binding(
                        get: { model.value ?? value },
                        set: { requested in Task { await model.set(requested) } })
                )
                .disabled(model.saving || model.load.isRunning)
            } else if model.failure == nil {
                SkeletonGroup {
                    LabeledContent("Pause scheduled jobs on battery") {
                        SkeletonBlock(width: 32, height: 18, corner: 9)
                    }
                }
            } else {
                LabeledContent("Pause scheduled jobs on battery", value: "Unavailable")
            }
            Text(
                "Saves power while your Mac is unplugged. Pages you have open keep updating, and anything you start yourself still runs. Jobs that always pause on battery keep doing so."
            )
            .settingsCaption()
            ForEach(failedOwners, id: \.identity.id) { owner in
                HostBackgroundNotice(
                    text: "\(owner.identity.id) did not apply this setting."
                        + (owner.failure.map { " " + $0 } ?? ""))
            }
            if let failure = model.failure, model.owner != nil {
                HostBackgroundNotice(text: failure)
            }
            if model.owner != nil && (model.failure != nil || !failedOwners.isEmpty) {
                Button("Try again") { Task { await model.refresh() } }
                    .buttonStyle(.edith(.secondary))
                    .disabled(model.owner == nil || model.load.isRunning || model.saving)
            }
        }
        .pageTask(id: model.owner, cancel: model.cancel) { await model.refresh() }
    }
}

enum HostCompactDuration {
    static func text(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}

struct HostBackgroundRowsSkeleton: View {
    var count: Int

    var body: some View {
        SkeletonGroup {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: UIScale.pt(12)) {
                    SkeletonBlock(width: 8, height: 8, corner: 4)
                    VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                        SkeletonBlock(width: 160, height: 12)
                        SkeletonBlock(width: 240, height: 10)
                    }
                    Spacer(minLength: UIScale.pt(24))
                    SkeletonBlock(width: 64, height: 22, corner: 6)
                }
                .padding(.vertical, UIScale.pt(4))
            }
        }
    }
}

struct HostBackgroundNotice: View {
    let text: String
    var symbol = "exclamationmark.triangle.fill"

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.orange)
        }
        .font(.edithText(.caption))
        .foregroundStyle(.primary)
    }
}

struct HostBackgroundEmptyRow: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: UIScale.pt(12)) {
            PageGuideBadge(symbolName: symbol, size: 32)
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(title).font(.edithText(.body)).fontWeight(.medium)
                Text(message).font(.edithText(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, UIScale.pt(4))
        .accessibilityElement(children: .combine)
    }
}

struct HostBackgroundOverviewSection: View {
    let status: HostBackgroundStatus
    let overview: HostBackgroundOverview
    let now: Date
    var actions = HostBackgroundActions()

    private var headline: String {
        switch status.phase {
        case .running: "Background agent is running"
        case .starting: "Starting the background agent"
        case .stopped: "Background agent is not running"
        case .failed: "Background agent stopped"
        }
    }

    private var subline: String {
        switch status.phase {
        case .running: overview.sentence
        case .starting: "This usually takes a moment."
        case .stopped: "Scheduled jobs and long tasks are paused until it starts again."
        case .failed: status.failure ?? "It stopped unexpectedly."
        }
    }

    private var tint: Color {
        switch status.phase {
        case .running: .green
        case .starting: .secondary
        case .stopped, .failed: .orange
        }
    }

    private var registrationNotice: String? {
        switch status.registration {
        case .enabled: nil
        case .awaitingApproval:
            "Allow Edith in System Settings under General, Login Items so background work keeps running after you log out and back in."
        case .notRegistered, .notFound:
            "Edith is not set to open at login, so background work only runs while Edith is open."
        }
    }

    var body: some View {
        Section {
            HStack(alignment: .center, spacing: UIScale.pt(12)) {
                PageGuideBadge(symbolName: "bolt.horizontal.circle.fill", size: 32, tint: tint)
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text(headline).font(.edithText(.headline))
                        .accessibilityAddTraits(.isHeader)
                    Text(subline).font(.edithText(.callout)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: UIScale.pt(8))
                if status.phase != .starting {
                    Button(status.phase == .stopped ? "Start" : "Restart", action: actions.restart)
                        .buttonStyle(.edith(status.phase == .running ? .secondary : .primary))
                        .help(
                            status.phase == .stopped
                                ? "Start the background agent"
                                : "Stop the background agent and start it again")
                }
            }
            .padding(.vertical, UIScale.pt(4))
            if status.phase == .running || status.phase == .starting {
                HostBackgroundMetrics(status: status, now: now)
            }
            Text(
                "Edith keeps this small helper running so your tools can refresh data, watch folders and finish long tasks while the window is closed. Closing the window or pressing \u{2318}W never stops it. To stop everything, choose Quit Edith (\u{2325}\u{2318}Q)."
            )
            .settingsCaption()
            .fixedSize(horizontal: false, vertical: true)
            if let registrationNotice {
                HStack(alignment: .center, spacing: UIScale.pt(12)) {
                    HostBackgroundNotice(text: registrationNotice)
                    Spacer(minLength: UIScale.pt(8))
                    Button("Open Login Items", action: actions.openLoginItems)
                        .buttonStyle(.edith(.secondary))
                }
            }
        }
    }
}

struct HostBackgroundMetrics: View {
    let status: HostBackgroundStatus
    let now: Date

    private var values: [(String, String?)] {
        [
            (
                "Running for",
                status.startedAt.map { HostCompactDuration.text(max(0, now.timeIntervalSince($0))) }
            ),
            (
                "Memory",
                status.residentBytes.map {
                    ByteCountFormatter.string(
                        fromByteCount: Int64(clamping: $0), countStyle: .memory)
                }
            ),
            ("CPU", status.phase == .running ? String(format: "%.1f%%", status.cpuPercent) : nil),
        ]
    }

    var body: some View {
        PageMetricGrid(minimumWidth: 120, maximumColumns: 3) {
            ForEach(values, id: \.0) { title, value in
                if let value {
                    PageMetric(title: title, value: value)
                } else {
                    PageMetricSkeleton()
                }
            }
        }
    }
}

struct HostBackgroundJobsSection: View {
    @Bindable var model: HostBackgroundModel
    var phase = HostBackgroundStatus.Phase.running
    var now = Date()
    var destination: (String) -> HostNavigationPage? = { _ in nil }
    var open: (String) -> Void = { _ in }

    var body: some View {
        let groups = model.groups(titles: { destination($0)?.title })
        if model.jobs.isEmpty {
            Section("Scheduled jobs") {
                if phase == .starting
                    || (model.failure == nil && model.unavailable == nil
                        && (model.load.state == .loading || model.load.isRunning))
                {
                    HostBackgroundRowsSkeleton(count: 3)
                } else if phase != .running {
                    HostBackgroundEmptyRow(
                        symbol: "pause.circle", title: "Jobs are paused",
                        message:
                            "Scheduled jobs run again as soon as the background agent is back. Use Restart above to bring it back now."
                    )
                } else if let failure = model.failure {
                    HostBackgroundNotice(text: failure)
                    Button("Try again") { Task { await model.refresh() } }
                        .buttonStyle(.edith(.secondary))
                } else if let unavailable = model.unavailable {
                    HostBackgroundEmptyRow(
                        symbol: "calendar.badge.exclamationmark", title: "Jobs are not available",
                        message: unavailable)
                } else {
                    HostBackgroundEmptyRow(
                        symbol: "calendar.badge.clock", title: "No scheduled jobs yet",
                        message:
                            "Tools like Usage refresh their data on a schedule. When you add one, its jobs show up here with when they last ran."
                    )
                }
            }
        } else {
            if model.failure != nil || model.unavailable != nil {
                Section {
                    if let failure = model.failure { HostBackgroundNotice(text: failure) }
                    if let unavailable = model.unavailable {
                        HostBackgroundNotice(text: unavailable, symbol: "info.circle.fill")
                    }
                }
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.jobs) { job in
                        HostBackgroundJobRow(
                            job: job, status: model.lastStatus(for: job), now: now,
                            busy: model.action == job.id,
                            enabled: model.current && model.action == nil,
                            perform: { Task { await model.control(job) } })
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(
                            group.ownerID.isEmpty
                                ? "Jobs built into Edith" : "Jobs from \(group.title)")
                        Spacer(minLength: UIScale.pt(8))
                        if !group.ownerID.isEmpty, let page = destination(group.ownerID) {
                            Button {
                                open(page.id)
                            } label: {
                                Label("Open \(page.title)", systemImage: "arrow.up.forward")
                                    .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(.edith(.borderless))
                            .font(.edithText(.caption))
                            .help("Go to \(page.title)")
                        }
                    }
                }
            }
        }
    }
}

struct HostBackgroundJobRow: View {
    let job: HostBackgroundJob
    var status: String? = nil
    var now = Date()
    var busy = false
    var enabled = true
    var perform: () -> Void = {}

    private var tint: Color {
        job.needsAttention ? .orange : job.isRunning ? .green : .secondary
    }

    var body: some View {
        HStack(alignment: .center, spacing: UIScale.pt(12)) {
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(8)) {
                    Text(job.descriptor.title).font(.edithText(.body)).fontWeight(.medium)
                        .lineLimit(1)
                    Text(job.statusTitle)
                        .font(.edithText(.caption)).fontWeight(.medium)
                        .foregroundStyle(tint)
                        .padding(.horizontal, UIScale.pt(6))
                        .padding(.vertical, UIScale.pt(1))
                        .background(tint.opacity(0.12), in: Capsule())
                        .fixedSize()
                }
                Text(job.details(now: now))
                    .font(.edithText(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = job.lastError ?? (job.needsAttention ? status : nil) {
                    Text(error)
                        .font(.edithText(.caption)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: UIScale.pt(8))
            if let title = job.actionTitle {
                Button(title, action: perform)
                    .buttonStyle(.edith(.secondary))
                    .disabled(!enabled || busy)
                    .help(
                        job.isRunning
                            ? "Stop this job before it finishes"
                            : "Run this job now instead of waiting for its schedule")
            }
        }
        .padding(.vertical, UIScale.pt(2))
        .accessibilityElement(children: .contain)
    }
}

struct HostBackgroundTasksSection: View {
    let status: HostBackgroundStatus
    var now = Date()
    var cancel: (UUID) async throws -> Void = { _ in }
    var visibleLimit = 6
    @State private var expanded = false
    @State private var stopping: Set<UUID> = []
    @State private var failure: String?
    @Environment(\.colorScheme) private var scheme

    private func symbol(_ state: HostBackgroundTask.State) -> (String, Color) {
        switch state {
        case .queued: ("clock", .secondary)
        case .running, .stopping: ("arrow.triangle.2.circlepath", DashSkin.accent(scheme == .dark))
        case .finished: ("checkmark.circle.fill", .green)
        case .failed, .interrupted: ("exclamationmark.circle.fill", .orange)
        case .cancelled: ("stop.circle", .secondary)
        }
    }

    var body: some View {
        let tasks = status.tasks
        let visible = expanded ? tasks : Array(tasks.prefix(visibleLimit))
        Section {
            if tasks.isEmpty && status.phase == .starting {
                HostBackgroundRowsSkeleton(count: 2)
            } else if tasks.isEmpty && status.phase != .running {
                HostBackgroundEmptyRow(
                    symbol: "checklist", title: "No tasks to show",
                    message:
                        "Tasks and their results show up here once the background agent is running."
                )
            } else if tasks.isEmpty {
                HostBackgroundEmptyRow(
                    symbol: "checklist", title: "No tasks yet",
                    message:
                        "Long actions you or an agent start, like downloads or commands run with ed, show their progress and result here."
                )
            }
            ForEach(visible) { task in
                row(task)
            }
            if let failure { HostBackgroundNotice(text: failure) }
            if tasks.count > visibleLimit {
                Button(expanded ? "Show fewer" : "Show all \(tasks.count) tasks") {
                    expanded.toggle()
                }
                .buttonStyle(.edith(.borderless))
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent tasks")
                Spacer(minLength: UIScale.pt(8))
                if status.activeTasks > 0 {
                    Text("\(status.activeTasks) active").monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            if !tasks.isEmpty {
                Text(
                    "Finished tasks stay here after Edith restarts. Command output can include details from the tools you run."
                )
                .settingsCaption()
            }
        }
    }

    private func row(_ task: HostBackgroundTask) -> some View {
        let (name, color) = symbol(task.state)
        let detail = task.failure ?? task.activity ?? task.timing(now: now)
        return HStack(alignment: .center, spacing: UIScale.pt(12)) {
            Image(systemName: name)
                .font(.system(size: UIScale.pt(14), weight: .medium))
                .foregroundStyle(color)
                .frame(width: UIScale.pt(20), height: UIScale.pt(20))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(task.title).font(.edithText(.body)).fontWeight(.medium).lineLimit(1)
                Text(detail)
                    .font(.edithText(.caption))
                    .foregroundStyle(
                        task.failure != nil && task.state.attention ? .orange : .secondary
                    )
                    .lineLimit(2)
            }
            Spacer(minLength: UIScale.pt(8))
            if task.cancellable {
                Button(stopping.contains(task.id) ? "Stopping" : "Stop") {
                    stop(task)
                }
                .buttonStyle(.edith(.secondary))
                .disabled(stopping.contains(task.id))
                .help("Stop this task")
            } else {
                Text(task.state.title)
                    .font(.edithText(.caption))
                    .foregroundStyle(task.state.attention ? .orange : .secondary)
            }
        }
        .padding(.vertical, UIScale.pt(2))
        .help(task.operation.map { "\(task.title) (\($0))" } ?? task.title)
        .contextMenu {
            Button("Copy Task ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(task.id.uuidString, forType: .string)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func stop(_ task: HostBackgroundTask) {
        stopping.insert(task.id)
        failure = nil
        Task {
            defer { stopping.remove(task.id) }
            do { try await cancel(task.id) } catch {
                failure = "\(task.title) could not be stopped. It may have already finished."
            }
        }
    }
}

struct HostBackgroundDiagnosticsSection: View {
    let status: HostBackgroundStatus
    @Binding var showingEvents: Bool
    var actions = HostBackgroundActions()

    var body: some View {
        Section("Troubleshooting") {
            Button {
                showingEvents = true
            } label: {
                HStack(spacing: UIScale.pt(12)) {
                    Label("Event timeline", systemImage: "waveform.path.ecg")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: UIScale.pt(10), weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, UIScale.pt(4))
                .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))
            HStack(alignment: .center, spacing: UIScale.pt(12)) {
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text("Logs")
                    Text("Copies a Terminal command that shows the last hour of Edith's logs.")
                        .settingsCaption()
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: UIScale.pt(8))
                Button("Copy command", action: actions.copyLogCommand)
                    .buttonStyle(.edith(.secondary))
            }
            if let failure = status.panelFailure {
                HostBackgroundNotice(text: failure)
            }
            DisclosureGroup("Technical details") {
                LabeledContent("Login item", value: status.registration.title)
                LabeledContent("Build", value: status.build)
                if let pid = status.processIdentifier {
                    LabeledContent("Process", value: String(pid)).monospacedDigit()
                }
                if let schema = status.schemaVersion {
                    LabeledContent("Store schema", value: String(schema))
                }
            }
        }
    }
}

struct HostBackgroundEventTimeline: View {
    @Bindable var model: HostBackgroundModel
    @State private var timeline: HostBackgroundTimelineModel
    @Environment(\.dismiss) private var dismiss

    init(model: HostBackgroundModel) {
        self.model = model
        let timeline = HostBackgroundTimelineModel()
        timeline.receive(model.events)
        _timeline = State(initialValue: timeline)
    }

    var body: some View {
        Form {
            Section("Event timeline") {
                TextField("Search events", text: $timeline.search)
                Toggle("Failures only", isOn: $timeline.failuresOnly)
                HStack {
                    Button(timeline.paused ? "Resume" : "Pause") {
                        timeline.paused.toggle()
                        timeline.receive(model.events)
                    }
                    Button("Copy events") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(timeline.text, forType: .string)
                    }.disabled(timeline.matches.isEmpty)
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                if timeline.matches.isEmpty {
                    Text(
                        model.failure ?? model.unavailable
                            ?? (timeline.events.isEmpty
                                ? "No background events have been recorded."
                                : "No matching events.")
                    )
                    .settingsCaption()
                }
                ForEach(timeline.visibleEvents) { event in
                    VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                        HStack {
                            Text(event.name)
                            Spacer()
                            Text(event.level.capitalized)
                                .foregroundStyle(
                                    event.level == "error"
                                        ? .red : event.level == "warning" ? .orange : .secondary)
                        }
                        Text(event.message).textSelection(.enabled)
                        Text(event.date.formatted() + " · " + event.category).settingsCaption()
                        if let duration = event.duration {
                            Text(
                                Duration.seconds(duration).formatted(
                                    .units(
                                        allowed: [.hours, .minutes, .seconds], width: .abbreviated))
                            ).settingsCaption()
                        }
                        if let task = event.taskID {
                            Text(task.uuidString).settingsCaption().textSelection(.enabled)
                        }
                    }
                }
                if timeline.hasMore {
                    Button("Load more events") { timeline.loadMore() }
                }
            }
        }
        .edithForm()
        .onChange(of: model.events) { _, events in timeline.receive(events) }
    }
}
