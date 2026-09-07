import AppKit
import EdithKit
import SwiftUI

@MainActor
@Observable
final class AgentEventsModel {
    static let pageSize = 50
    private(set) var events: [AgentEvent] = []
    private(set) var matches: [AgentEvent] = []
    private(set) var visibleCount = pageSize
    private(set) var loading = true
    var failure: String?
    var paused = false
    private var search = ""
    private var errorsOnly = false

    var visibleEvents: ArraySlice<AgentEvent> { matches.prefix(visibleCount) }
    var hasMore: Bool { visibleCount < matches.count }

    func receive(_ events: [AgentEvent]) {
        self.events = Array(events.suffix(AgentDiagnostics.capacity))
        loading = false
        failure = nil
        rebuildMatches()
    }

    func filter(search: String, errorsOnly: Bool) {
        self.search = search.trimmingCharacters(in: .whitespacesAndNewlines)
        self.errorsOnly = errorsOnly
        visibleCount = Self.pageSize
        rebuildMatches()
    }

    func loadMore() {
        visibleCount = min(visibleCount + Self.pageSize, matches.count)
    }

    private func rebuildMatches() {
        matches = events.reversed().filter { event in
            (!errorsOnly || event.level != .info)
                && (search.isEmpty
                    || [event.category, event.name, event.message, event.taskID?.uuidString ?? ""]
                        .contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }

    func observe() async {
        guard !paused else { return }
        if events.isEmpty { loading = true }
        do {
            let value = try await AgentClient.shared.snapshotAsync(
                [AgentEvent].self, topic: .events)
            try Task.checkCancellation()
            receive(value)
        } catch is CancellationError {
            return
        } catch {
            loading = false
            failure = error.localizedDescription
        }
        for await events in AgentTopicStream.values([AgentEvent].self, topic: .events) {
            guard !Task.isCancelled, !paused else { return }
            receive(events)
        }
    }

    func copyEvents() async {
        let events = Array(matches.reversed())
        let value = await Task.detached(priority: .userInitiated) {
            events.map { event in
                let task = event.taskID.map { " [task \($0.uuidString)]" } ?? ""
                return
                    "\(event.date.ISO8601Format()) [\(event.level.rawValue)] \(event.category).\(event.name)\(task): \(event.message)"
            }.joined(separator: "\n")
        }.value
        guard !Task.isCancelled else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

struct AgentEventsScreen: View {
    @State var model = AgentEventsModel()
    @State private var search = ""
    @State private var errorsOnly = false
    @State private var retryID = 0
    @State private var copyTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Event timeline").font(.title2.bold())
                    Text("Recent background activity on this Mac")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Label(
                    model.paused ? "Paused" : "Live",
                    systemImage: model.paused ? "pause.circle" : "dot.radiowaves.left.and.right"
                )
                .foregroundStyle(model.paused ? .secondary : Color.accentColor)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            HStack {
                TextField("Search events", text: $search).textFieldStyle(.roundedBorder)
                Toggle("Failures", isOn: $errorsOnly).toggleStyle(.button)
                Button(model.paused ? "Resume" : "Pause") { model.paused.toggle() }
                Button("Copy") {
                    copyTask?.cancel()
                    copyTask = Task { await model.copyEvents() }
                }
                .disabled(model.matches.isEmpty)
            }
            .padding(.horizontal, 20).padding(.bottom, 12)
            Divider()
            eventList
            Divider()
            HStack {
                Text(
                    "\(min(model.visibleCount, model.matches.count)) of \(model.matches.count) matching events"
                )
                Spacer()
                Text("Up to \(AgentDiagnostics.capacity) events retained")
            }
            .font(.caption).foregroundStyle(.secondary).padding(16)
        }
        .frame(minWidth: 680, idealWidth: 840, minHeight: 460, idealHeight: 620)
        .task(id: "\(model.paused)-\(retryID)") {
            guard automaticActionsEnabled else { return }
            await model.observe()
        }
        .task(id: search) {
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            model.filter(search: search, errorsOnly: errorsOnly)
        }
        .onChange(of: errorsOnly) { _, value in model.filter(search: search, errorsOnly: value) }
        .onDisappear { copyTask?.cancel() }
    }

    @ViewBuilder
    private var eventList: some View {
        if model.loading {
            List { AgentRowsSkeleton(count: 9, timeline: true) }
                .listStyle(.plain)
        } else if let failure = model.failure, model.events.isEmpty {
            ContentUnavailableView {
                Label("Agent unavailable", systemImage: "exclamationmark.circle")
            } description: {
                Text(failure)
            } actions: {
                Button("Retry") {
                    model.paused = false
                    retryID += 1
                }
            }
            .frame(maxHeight: .infinity)
        } else if model.matches.isEmpty {
            ContentUnavailableView(
                model.events.isEmpty ? "Waiting for events" : "No matching events",
                systemImage: "waveform.path.ecg",
                description: Text(
                    model.events.isEmpty
                        ? "Run a background job to follow its activity here."
                        : "Change the search or turn off the failures filter.")
            )
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(model.visibleEvents) { event in
                    AgentEventRow(event: event)
                }
                if model.hasMore {
                    Button("Load more events") { model.loadMore() }
                        .frame(maxWidth: .infinity)
                        .onAppear { model.loadMore() }
                }
            }
            .listStyle(.plain)
        }
    }
}

struct AgentRowsSkeleton: View {
    var count: Int
    var timeline = false

    var body: some View {
        SkeletonGroup {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: 12) {
                    if timeline {
                        SkeletonBlock(width: 12, height: 12, corner: 6)
                        SkeletonBlock(width: 60, height: 10)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonBlock(width: 160, height: 12)
                        SkeletonBlock(height: 10)
                    }
                    Spacer(minLength: 30)
                    SkeletonBlock(width: 48, height: 10)
                }
                .padding(.vertical, 6)
            }
        }
    }
}
