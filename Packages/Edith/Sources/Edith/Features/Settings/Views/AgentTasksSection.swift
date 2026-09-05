import EdithKit
import SwiftUI

struct AgentTasksSection: View {
    let tasks: [AgentTaskSnapshot]
    @State private var expandedID: UUID?
    @State private var detail: AgentTaskStatus?
    @State private var failure: String?

    private var ordered: [AgentTaskSnapshot] {
        tasks.sorted {
            if $0.state.isTerminal != $1.state.isTerminal { return !$0.state.isTerminal }
            return $0.submittedAt > $1.submittedAt
        }
    }

    var body: some View {
        Section {
            if tasks.isEmpty {
                Text("Long-running actions appear here with their progress and result.")
                    .settingsCaption()
            }
            ForEach(ordered) { task in
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedID == task.id },
                        set: { expandedID = $0 ? task.id : nil })
                ) {
                    taskDetails(task)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.title).fontWeight(.medium)
                            if let activity = task.lastActivity {
                                Text(activity).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(task.state.rawValue.capitalized)
                            .font(.caption)
                            .foregroundStyle(
                                task.state == .failed || task.state == .interrupted
                                    ? .orange : .secondary)
                    }
                }
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            HStack {
                Text("Background tasks")
                Spacer()
                Text("\(tasks.filter { !$0.state.isTerminal }.count) active")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text(
                "Completed tasks remain available after restarting Edith. Command output may contain information from the tools you run."
            )
        }
        .task(id: expandedID) { await observeDetail() }
    }

    @ViewBuilder
    private func taskDetails(_ task: AgentTaskSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Operation", value: task.operation)
            LabeledContent("Submitted", value: task.submittedAt.formatted())
            if let started = task.startedAt {
                LabeledContent("Started", value: started.formatted())
            }
            if let finished = task.finishedAt {
                LabeledContent("Finished", value: finished.formatted())
            }
            if let error = task.failure {
                Text(error).foregroundStyle(.orange).textSelection(.enabled)
            }
            if !task.state.isTerminal {
                Button(task.state == .cancelling ? "Cancelling" : "Cancel task") {
                    Task { await cancel(task.id) }
                }
                .disabled(task.state == .cancelling)
            }
            if let detail, detail.snapshot.id == task.id, !detail.output.isEmpty {
                ScrollView {
                    Text(detail.output.map(\.text).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .font(.caption)
        .padding(.vertical, 8)
    }

    @MainActor
    private func observeDetail() async {
        detail = nil
        failure = nil
        guard let id = expandedID else { return }
        while !Task.isCancelled {
            do {
                let value = try await AgentTaskClient().status(id)
                try Task.checkCancellation()
                detail = value
                failure = nil
                if value.snapshot.state.isTerminal { return }
                try await Task.sleep(for: .seconds(1))
            } catch is CancellationError {
                return
            } catch {
                failure = error.localizedDescription
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    @MainActor
    private func cancel(_ id: UUID) async {
        do {
            _ = try await AgentTaskClient().cancel(id)
            failure = nil
        } catch { failure = error.localizedDescription }
    }
}
