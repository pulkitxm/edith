import EdithKit
import SwiftUI

private struct MachineProcessRequest: Equatable {
    let timestamp: Double?
    let query: String
    let sortByMemory: Bool
}

struct MachineProcessesTab: View {
    let session: MachineSession
    @Environment(\.windowSessionOwner) private var owner
    @Environment(\.compactLayout) private var compact
    @Environment(\.machineViewPresented) private var presented
    @State private var fallback = MachineProcessListModel()
    @State private var pendingKill: MachineProcess?
    @State private var message: String?
    @State private var columns = TableColumnCustomization<MachineProcess>()

    private var model: MachineProcessListModel { owner?.processes(for: session.id) ?? fallback }

    var body: some View {
        @Bindable var model = model
        PageWorkspace {
            controls
            if let message {
                PageNotice(message, tone: .error)
                    .pageGutter(compact)
                    .padding(.bottom, UIScale.pt(8))
            }
        } content: {
            LoadingContainer(
                state: model.loading.state,
                message: model.loading.errorMessage ?? "Waiting for a process sample.",
                refreshing: model.loading.isRefreshing
            ) {
                GeometryReader { geometry in
                    Table(model.rows, selection: $model.selectedPID, columnCustomization: $columns)
                    {
                        SwiftUI.TableColumn("Process") { process in
                            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                                Text(process.name.isEmpty ? process.cmd : process.name)
                                    .font(.edithText(.body)).lineLimit(1)
                                Text(compact ? "\(process.user) · PID \(process.pid)" : process.cmd)
                                    .font(.edithText(.caption)).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            .help("PID \(process.pid) · \(process.user)\n\(process.cmd)")
                        }
                        .width(
                            PageMetrics.tableNameWidth(
                                viewport: geometry.size.width,
                                fixedWidth: (compact ? 0 : 100) + 64 + 90
                                    + (session.isLocal ? 0 : 44),
                                columnCount: (compact ? 3 : 4) + (session.isLocal ? 0 : 1)))
                        SwiftUI.TableColumn("User") { Text($0.user).lineLimit(1) }
                            .width(UIScale.pt(100))
                            .customizationID("user")
                            .defaultVisibility(compact ? .hidden : .visible)
                        SwiftUI.TableColumn("CPU") { process in
                            Text(String(format: "%.1f%%", process.cpu)).monospacedDigit()
                                .foregroundStyle(process.cpu > 50 ? DashSkin.warn : .primary)
                        }
                        .width(UIScale.pt(64))
                        SwiftUI.TableColumn("Memory") { process in
                            Text(ByteFormatter.string(process.rssKB * 1024)).monospacedDigit()
                        }
                        .width(UIScale.pt(90))
                        SwiftUI.TableColumn("End") { process in
                            Button {
                                pendingKill = process
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.edith(.iconOnly))
                            .help("End \(process.name), PID \(process.pid)")
                            .accessibilityLabel("End \(process.name), PID \(process.pid)")
                        }
                        .width(UIScale.pt(44))
                        .customizationID("end")
                        .defaultVisibility(session.isLocal ? .hidden : .visible)
                        .disabledCustomizationBehavior(.visibility)
                    }
                    .font(.edithText(.callout))
                    .accessibilityLabel("Machine processes")
                    .onChange(of: compact, initial: true) { _, compact in
                        columns[visibility: "user"] = compact ? .hidden : .visible
                    }
                    .overlay {
                        if model.rows.isEmpty { ContentUnavailableView.search(text: model.query) }
                    }
                }
            } placeholder: {
                MachineProcessRowsSkeleton(showsActions: !session.isLocal)
            }
            .padding(.horizontal, PageMetrics.gutter(compact))
            .padding(.bottom, UIScale.pt(12))
        }
        .pageTask(
            id: MachineProcessRequest(
                timestamp: session.sample?.ts, query: model.query, sortByMemory: model.sortByMemory),
            active: presented && session.sample != nil, cancel: { model.loading.cancel() }
        ) {
            await model.refresh(session.sample?.procs ?? [])
        }
        .confirmationDialog(
            "End \(pendingKill?.name ?? "process")?",
            isPresented: Binding(
                get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } }),
            titleVisibility: .visible
        ) {
            Button("Terminate (SIGTERM)") { kill(signal: "TERM") }
            Button("Force kill (SIGKILL)", role: .destructive) { kill(signal: "KILL") }
            Button("Cancel", role: .cancel) { pendingKill = nil }
        } message: {
            Text("PID \(pendingKill.map { String($0.pid) } ?? "")")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: UIScale.pt(12)) {
                    search
                    sorting.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                    search
                    sorting
                }
            }
            Text("\(model.rows.count) of \(model.totalCount) processes · sampled every 2s")
                .font(.edithText(.caption)).foregroundStyle(.secondary)
        }
        .pageGutter(compact)
        .padding(.bottom, UIScale.pt(12))
    }

    private var search: some View {
        @Bindable var model = model
        return SearchField(placeholder: "Filter name, command, user or PID", text: $model.query)
    }

    private var sorting: some View {
        @Bindable var model = model
        return EdithSegmentedPicker(
            "Sort processes", selection: $model.sortByMemory, options: [false, true],
            label: { $0 ? "Memory" : "CPU" }
        )
        .labelsHidden().frame(width: UIScale.pt(160))
    }

    private func kill(signal: String) {
        guard !session.isLocal, let process = pendingKill else { return }
        pendingKill = nil
        Task {
            let result = await MachineProcessOperationExecution.perform(
                pid: process.pid, signal: signal,
                platform: session.remotePlatform ?? .linux,
                using: { command, timeout in
                    await session.runCommand(command, timeout: timeout)
                })
            switch result {
            case let .success(outcome):
                message = outcome.alreadyExited ? "\(process.name) had already exited." : nil
            case let .failure(error):
                message = "Could not end \(process.name): \(error.localizedDescription)"
            }
        }
    }
}
