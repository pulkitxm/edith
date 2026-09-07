import AppKit
import EdithKit
import Observation
import SwiftUI

@MainActor
@Observable
final class DockerDetailModel {
    var logs: [DockerLogLine] = []
    var inspect: DockerInspectSummary?
    var processes: [DockerProcess] = []
    var files: [RemoteFileEntry] = []
    var filePath = "/"
    var cpuHistory: [Double] = []
    var memHistory: [Double] = []
    var follow = true
    var wrapLines = DockerLogDefaults.wrapLines {
        didSet { DockerLogDefaults.wrapLines = wrapLines }
    }
    var logFontSize = DockerLogDefaults.fontSize {
        didSet { DockerLogDefaults.fontSize = logFontSize }
    }
    var showTimestamps = DockerLogDefaults.showTimestamps {
        didSet { DockerLogDefaults.showTimestamps = showTimestamps }
    }
    private(set) var streamEnded = false
    var logFilter = ""

    var inspectFailed = false
    var processesFailed = false
    private(set) var inspectLoading = false
    private(set) var processesLoading = false
    private(set) var processesLoaded = false
    private(set) var filesLoading = false
    private(set) var filesLoaded = false
    private(set) var filesFailed = false

    private var stream: SSHLineStream?
    private var nextLogID = 0
    private var logGeneration = 0
    private var fileToken = 0
    private var pending: [DockerLogLine] = []
    private var flushTask: Task<Void, Never>?
    private var reattempts = 0
    private var detailContainerID: String?
    private var inspectRequest = 0
    private var processesRequest = 0
    private var logsSuspended = false
    private let logProcess: @MainActor (MachineSession, DockerContainer) -> Process?

    init(
        logProcess: @escaping @MainActor (MachineSession, DockerContainer) -> Process? = {
            session, container in
            session.connectionRef?.streamProcess(
                command: DockerCommands.logs(
                    container.id, tail: 400, follow: true,
                    platform: session.remotePlatform ?? .linux))
        }
    ) {
        self.logProcess = logProcess
    }

    func activate(session: MachineSession, container: DockerContainer, streamLogs: Bool = true)
        -> Bool
    {
        guard detailContainerID != container.id else {
            if streamLogs, logsSuspended {
                logsSuspended = false
                logs = []
                nextLogID = 0
                reattempts = 0
                attachLogs(session: session, container: container, generation: logGeneration)
            } else if !streamLogs, !logsSuspended {
                stopLogs()
                logsSuspended = true
            }
            return false
        }
        startLogs(session: session, container: container, streamLogs: streamLogs)
        return true
    }

    var logPlainText: String {
        visibleLogs.map { line in
            guard showTimestamps, let stamp = line.timestamp else { return line.text }
            return stamp + "  " + line.text
        }.joined(separator: "\n")
    }

    var visibleLogs: [DockerLogLine] {
        let trimmed = logFilter.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return logs }
        return logs.filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
    }

    func startLogs(session: MachineSession, container: DockerContainer, streamLogs: Bool = true) {
        stopLogs()
        logs = []
        nextLogID = 0
        cpuHistory = []
        memHistory = []
        processes = []
        files = []
        filePath = "/"
        inspect = nil
        inspectFailed = false
        processesFailed = false
        inspectLoading = false
        processesLoading = false
        processesLoaded = false
        filesLoading = false
        filesLoaded = false
        filesFailed = false
        detailContainerID = container.id
        inspectRequest &+= 1
        processesRequest &+= 1
        fileToken &+= 1
        streamEnded = false
        reattempts = 0
        logGeneration += 1
        logsSuspended = !streamLogs
        if streamLogs {
            attachLogs(session: session, container: container, generation: logGeneration)
        }
    }

    private func attachLogs(
        session: MachineSession, container: DockerContainer, generation: Int
    ) {
        guard let process = logProcess(session, container) else { return }
        let stream = SSHLineStream(
            process: process,
            onLine: { [weak self] text, isStderr in
                Task { @MainActor in
                    guard let self, generation == self.logGeneration else { return }
                    let line = DockerParsing.splitLogLine(
                        text, index: self.nextLogID, isStderr: isStderr)
                    self.nextLogID += 1
                    self.enqueue(line)
                }
            },
            onExit: { [weak self] _ in
                Task { @MainActor in
                    guard let self, generation == self.logGeneration else { return }
                    self.flushPending()
                    let running =
                        session.containers.first { $0.id == container.id }?.state.isRunning ?? false
                    guard running, self.reattempts < 5 else {
                        self.streamEnded = true
                        return
                    }
                    self.reattempts += 1
                    try? await Task.sleep(for: .seconds(2))
                    guard generation == self.logGeneration else { return }
                    self.attachLogs(
                        session: session, container: container, generation: generation)
                }
            })
        try? stream.start()
        self.stream = stream
    }

    func stopLogs() {
        logGeneration += 1
        flushTask?.cancel()
        flushTask = nil
        pending = []
        stream?.cancel()
        stream = nil
    }

    func stop() {
        suspend()
        detailContainerID = nil
    }

    func suspend() {
        stopLogs()
        logsSuspended = true
        inspectRequest &+= 1
        processesRequest &+= 1
        fileToken &+= 1
        inspectLoading = false
        processesLoading = false
        filesLoading = false
    }

    private func enqueue(_ line: DockerLogLine) {
        pending.append(line)
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self else { return }
            self.flushTask = nil
            self.flushPending()
        }
    }

    private func flushPending() {
        guard !pending.isEmpty else { return }
        logs.append(contentsOf: pending)
        pending = []
        if logs.count > 4000 { logs.removeFirst(logs.count - 4000) }
    }

    func loadInspect(session: MachineSession, container: DockerContainer) async {
        await loadInspect(
            container: container, platform: session.remotePlatform ?? .linux
        ) { command, timeout in
            await session.runCommand(command, timeout: timeout)
        }
    }

    func loadInspect(
        container: DockerContainer, platform: RemoteMachinePlatform = .linux,
        using run: DockerDetailOperationExecution.Run
    ) async {
        guard detailContainerID == container.id else { return }
        inspectRequest &+= 1
        let request = inspectRequest
        inspectFailed = false
        inspectLoading = true
        let result = await DockerDetailOperationExecution.inspect(
            containerID: container.id, platform: platform, using: run)
        guard
            !Task.isCancelled, detailContainerID == container.id, inspectRequest == request
        else { return }
        inspectLoading = false
        guard case let .success(summary) = result else {
            inspect = nil
            inspectFailed = true
            return
        }
        inspect = summary
    }

    func loadProcesses(session: MachineSession, container: DockerContainer) async {
        await loadProcesses(
            container: container, platform: session.remotePlatform ?? .linux
        ) { command, timeout in
            await session.runCommand(command, timeout: timeout)
        }
    }

    func loadProcesses(
        container: DockerContainer, platform: RemoteMachinePlatform = .linux,
        using run: DockerDetailOperationExecution.Run
    ) async {
        guard detailContainerID == container.id else { return }
        processesRequest &+= 1
        let request = processesRequest
        processesFailed = false
        processesLoading = true
        processesLoaded = false
        let result = await DockerDetailOperationExecution.processes(
            containerID: container.id, platform: platform, using: run)
        guard
            !Task.isCancelled, detailContainerID == container.id, processesRequest == request
        else { return }
        processesLoading = false
        processesLoaded = true
        guard case let .success(rows) = result else {
            processes = []
            processesFailed = true
            return
        }
        processes = rows
    }

    func loadFiles(session: MachineSession, container: DockerContainer, path: String) async {
        await loadFiles(
            container: container, path: path,
            platform: session.remotePlatform ?? .linux
        ) { command, timeout in
            await session.runCommand(command, timeout: timeout)
        }
    }

    func loadFiles(
        container: DockerContainer, path: String,
        platform: RemoteMachinePlatform = .linux,
        using run: DockerDetailOperationExecution.Run
    ) async {
        guard detailContainerID == container.id else { return }
        fileToken &+= 1
        let token = fileToken
        filePath = path
        filesLoading = true
        filesLoaded = false
        filesFailed = false
        let result = await run(
            DockerCommands.listFiles(
                containerID: container.id, path: path, platform: platform), 30)
        guard !Task.isCancelled, detailContainerID == container.id, token == fileToken else {
            return
        }
        filesLoading = false
        filesLoaded = true
        guard case let .success(output) = result else {
            files = []
            filesFailed = true
            return
        }
        files = FileListing.parse(output: output, parent: path)
    }

    func loadDetails(
        session: MachineSession, container: DockerContainer, tab: DockerDetailTab, filePath: String
    ) async {
        await loadDetails(container: container, tab: tab, filePath: filePath) { command, timeout in
            await session.runCommand(command, timeout: timeout)
        }
    }

    func loadDetails(
        container: DockerContainer, tab: DockerDetailTab, filePath: String,
        using run: @escaping DockerDetailOperationExecution.Run
    ) async {
        if tab == .inspect {
            await loadInspect(container: container, using: run)
            return
        }
        if inspect == nil, !inspectFailed {
            async let inspection: Void = loadInspect(container: container, using: run)
            await loadActiveDetail(container: container, tab: tab, filePath: filePath, using: run)
            await inspection
        } else {
            await loadActiveDetail(container: container, tab: tab, filePath: filePath, using: run)
        }
    }

    private func loadActiveDetail(
        container: DockerContainer, tab: DockerDetailTab, filePath: String,
        using run: DockerDetailOperationExecution.Run
    ) async {
        switch tab {
        case .processes: await loadProcesses(container: container, using: run)
        case .files: await loadFiles(container: container, path: filePath, using: run)
        default: break
        }
    }

    func record(container: DockerContainer) {
        if let cpu = container.cpuPercent {
            cpuHistory = MachineSession.appending(cpu, to: cpuHistory)
        }
        if let used = container.memUsedBytes, let limit = container.memLimitBytes, limit > 0 {
            memHistory = MachineSession.appending(
                Double(used) / Double(limit) * 100, to: memHistory)
        }
    }
}

private struct DockerDetailLoadRequest: Equatable {
    let containerID: String
    let tab: DockerDetailTab
    let filePath: String
    let generation: Int
    let presented: Bool
}

struct DockerContainerDetail: View {
    @Environment(\.machineViewPresented) private var presented
    let session: MachineSession
    let container: DockerContainer
    let dark: Bool
    let onBack: () -> Void
    let onAction: (String) -> Void
    let onShell: () -> Void
    let onRemove: () -> Void
    let onSwitch: (DockerContainer) -> Void

    @State private var model = DockerDetailModel()
    @State private var tab = DockerDetailTab.logs
    @State private var requestedFilePath = "/"
    @State private var loadGeneration = 0

    private var live: DockerContainer {
        session.containers.first { $0.id == container.id } ?? container
    }

    private var siblings: [DockerContainer] {
        session.containers
            .filter { $0.composeProject == live.composeProject }
            .sorted { $0.displayName < $1.displayName }
    }

    private var loadRequest: DockerDetailLoadRequest {
        DockerDetailLoadRequest(
            containerID: container.id, tab: tab, filePath: requestedFilePath,
            generation: loadGeneration, presented: presented)
    }

    private var browserPorts: [DockerPortMapping] {
        DockerBrowserOperationExecution.reachablePorts(in: live, for: session.machine)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            tabBar
            Divider().opacity(0.3)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: loadRequest) {
            guard presented else {
                model.suspend()
                return
            }
            let switched = model.activate(
                session: session, container: container, streamLogs: tab == .logs)
            if switched, requestedFilePath != "/" {
                requestedFilePath = "/"
                return
            }
            await model.loadDetails(
                session: session, container: container, tab: tab, filePath: requestedFilePath)
        }
        .onDisappear { model.stop() }
        .onChange(of: session.containers) { _, _ in
            if presented { model.record(container: live) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            HStack(spacing: UIScale.pt(10)) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.edith(.toolbar))
                .help("Back to the list")
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text(live.displayName)
                        .font(DashSkin.serif(20))
                        .foregroundStyle(DashSkin.ink(dark))
                    Text("\(live.image)  ·  \(live.shortID)")
                        .font(DashSkin.mono(10.5))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
                switcher
                Spacer(minLength: 0)
                statusPill
            }
            HStack(spacing: UIScale.pt(8)) {
                Button(live.state.isRunning ? "Stop" : "Start") {
                    onAction(live.state.isRunning ? "stop" : "start")
                }
                Button("Restart") { onAction("restart") }
                Button(live.state == .paused ? "Unpause" : "Pause") {
                    onAction(live.state == .paused ? "unpause" : "pause")
                }
                Button("Shell", action: onShell).disabled(!live.state.isRunning)
                Spacer(minLength: 0)
                ForEach(browserPorts.prefix(3), id: \.self) { port in
                    if let url = DockerBrowserOperationExecution.url(
                        for: port, machine: session.machine)
                    {
                        Button(port.displayName) {
                            RemoteFileOperationExecution.present([url], action: .open) { urls, _ in
                                NSWorkspace.shared.open(urls[0])
                            }
                        }
                    }
                }
                Button("Remove", role: .destructive, action: onRemove)
            }
            .font(.system(size: UIScale.pt(11.5)))
        }
        .padding(.horizontal, UIScale.pt(16))
        .padding(.vertical, UIScale.pt(12))
    }

    @ViewBuilder
    private var switcher: some View {
        if siblings.count > 1 {
            Menu {
                Section(live.composeProject ?? "Standalone") {
                    ForEach(siblings) { sibling in
                        Button {
                            guard sibling.id != live.id else { return }
                            onSwitch(sibling)
                        } label: {
                            Label(
                                sibling.composeService ?? sibling.displayName,
                                systemImage: symbol(for: sibling))
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: UIScale.pt(10), weight: .semibold))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .padding(.horizontal, UIScale.pt(7))
                    .padding(.vertical, UIScale.pt(5))
                    .background(
                        DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(7)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Switch to another container in this group")
        }
    }

    private func symbol(for sibling: DockerContainer) -> String {
        guard sibling.id != live.id else { return "checkmark" }
        return sibling.state.isRunning ? "circle.fill" : "circle"
    }

    private var statusPill: some View {
        HStack(spacing: UIScale.pt(6)) {
            Circle()
                .fill(live.state.isRunning ? DashSkin.ok : DashSkin.inkFaint(dark))
                .frame(width: UIScale.pt(7), height: UIScale.pt(7))
            Text(live.status)
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(DashSkin.inkSoft(dark))
        }
    }

    private var tabBar: some View {
        HStack(spacing: UIScale.pt(4)) {
            ForEach(DockerDetailTab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    Text(item.title)
                        .font(.system(size: UIScale.pt(12), weight: .medium))
                        .padding(.horizontal, UIScale.pt(11))
                        .padding(.vertical, UIScale.pt(5))
                        .foregroundStyle(tab == item ? DashSkin.ink(dark) : DashSkin.inkFaint(dark))
                        .background(
                            tab == item ? DashSkin.paper2(dark) : .clear,
                            in: RoundedRectangle(cornerRadius: UIScale.pt(7))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.edith(.borderless))
            }
            Spacer(minLength: 0)
            if tab == .logs {
                SearchField(placeholder: "Find in logs", text: $model.logFilter)
                    .frame(width: UIScale.pt(180))
                Toggle("Timestamps", isOn: $model.showTimestamps)
                    .toggleStyle(.checkbox)
                    .font(.system(size: UIScale.pt(11)))
                Toggle("Follow", isOn: $model.follow)
                    .toggleStyle(.checkbox)
                    .font(.system(size: UIScale.pt(11)))
                Toggle("Wrap", isOn: $model.wrapLines)
                    .toggleStyle(.checkbox)
                    .font(.system(size: UIScale.pt(11)))
                Button {
                    model.logFontSize = max(9, model.logFontSize - 1)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .buttonStyle(.edith(.toolbar))
                .help("Smaller log text")
                Button {
                    model.logFontSize = min(18, model.logFontSize + 1)
                } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .buttonStyle(.edith(.toolbar))
                .help("Larger log text")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.logPlainText, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.edith(.toolbar))
                .help("Copy all visible log lines")
                Button {
                    model.logs = []
                } label: {
                    Image(systemName: "clear")
                }
                .buttonStyle(.edith(.toolbar))
                .help("Clear the log view")
            }
        }
        .padding(.horizontal, UIScale.pt(16))
        .padding(.vertical, UIScale.pt(7))
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .logs: logsView
        case .inspect: inspectView
        case .stats: statsView
        case .processes: processesView
        case .files: filesView
        }
    }

    private var logsView: some View {
        let visible = model.visibleLogs
        return ZStack(alignment: .bottom) {
            LogTextView(
                document: LogDocument(
                    lines: visible, showTimestamps: model.showTimestamps,
                    wraps: model.wrapLines, fontSize: model.logFontSize),
                palette: LogPalette(
                    text: NSColor(DashSkin.inkSoft(dark)),
                    stderr: NSColor(DashSkin.warn),
                    timestamp: NSColor(DashSkin.inkFaint(dark)),
                    background: NSColor(DashSkin.paper(dark))),
                follow: model.follow,
                onScrolledAwayFromBottom: { away in
                    if away, model.follow { model.follow = false }
                })
            if visible.isEmpty {
                Text(model.logFilter.isEmpty ? "No output yet." : "Nothing matches that filter.")
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.streamEnded {
                HStack(spacing: UIScale.pt(8)) {
                    Text("The log stream ended.")
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                    Button("Reattach") {
                        model.startLogs(session: session, container: live)
                    }
                    .font(.system(size: UIScale.pt(11), weight: .medium))
                }
                .padding(.horizontal, UIScale.pt(12))
                .padding(.vertical, UIScale.pt(7))
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, UIScale.pt(12))
            }
        }
    }

    private var inspectView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(14)) {
                if let inspect = model.inspect {
                    section("Image", [inspect.image])
                    section("Command", [inspect.command])
                    section("Restart policy", [inspect.restartPolicy])
                    section("Networks", inspect.networks)
                    section("Mounts", inspect.mounts)
                    section("Environment", inspect.environment)
                    section(
                        "Labels", inspect.labels.sorted { $0.key < $1.key }.map { "\($0)=\($1)" })
                } else if model.inspectFailed {
                    HStack(spacing: UIScale.pt(8)) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(DashSkin.warn)
                        Text("Could not read this container's configuration.")
                            .font(.system(size: UIScale.pt(12)))
                            .foregroundStyle(DashSkin.inkSoft(dark))
                        Button("Retry") {
                            loadGeneration &+= 1
                        }
                        .font(.system(size: UIScale.pt(11), weight: .medium))
                    }
                } else {
                    DockerInspectSkeleton()
                }
            }
            .padding(UIScale.pt(16))
        }
    }

    private func section(_ title: String, _ values: [String]) -> some View {
        let shown = values.filter { !$0.isEmpty }
        return VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            HStack(spacing: UIScale.pt(6)) {
                Text(title.uppercased())
                    .font(.system(size: UIScale.pt(9.5), weight: .semibold))
                    .tracking(UIScale.pt(0.6))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                if !shown.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            shown.joined(separator: "\n"), forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: UIScale.pt(9)))
                    }
                    .buttonStyle(.edith(.borderless))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .help("Copy \(title)")
                }
                Spacer(minLength: 0)
            }
            if shown.isEmpty {
                Text("—")
                    .font(DashSkin.mono(11))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            ForEach(shown, id: \.self) { value in
                Text(value)
                    .font(DashSkin.mono(11))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .contextMenu {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(value, forType: .string)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statsView: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            statCard(
                "CPU", value: live.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—",
                history: model.cpuHistory, color: DashSkin.accent(dark))
            statCard(
                "Memory",
                value: live.memUsedBytes.map { ByteFormatter.string($0) } ?? "—",
                history: model.memHistory, color: DashSkin.sage)
            HStack(spacing: UIScale.pt(20)) {
                statItem("Network in", live.netRxBytes.map { ByteFormatter.string($0) } ?? "—")
                statItem("Network out", live.netTxBytes.map { ByteFormatter.string($0) } ?? "—")
                statItem(
                    "Memory limit", live.memLimitBytes.map { ByteFormatter.string($0) } ?? "—")
            }
            Spacer(minLength: 0)
        }
        .padding(UIScale.pt(16))
    }

    private func statCard(_ title: String, value: String, history: [Double], color: Color)
        -> some View
    {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: UIScale.pt(9.5), weight: .semibold))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                Spacer()
                Text(value)
                    .font(DashSkin.serif(18))
                    .foregroundStyle(DashSkin.ink(dark))
            }
            Sparkline(
                values: history, maximum: 100, color: color,
                cadence: MetricsCadence.dockerInterval
            )
            .frame(height: UIScale.pt(54))
        }
        .padding(UIScale.pt(14))
        .widgetBar(cornerRadius: 12, fill: DashSkin.paper2(dark))
    }

    private func statItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
            Text(label.uppercased())
                .font(.system(size: UIScale.pt(9), weight: .semibold))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Text(value)
                .font(DashSkin.mono(12))
                .foregroundStyle(DashSkin.ink(dark))
        }
    }

    private var processesView: some View {
        ScrollView {
            if model.processesLoading || !model.processesLoaded && !model.processesFailed {
                DockerProcessRowsSkeleton()
            } else if model.processesFailed {
                HStack(spacing: UIScale.pt(8)) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(DashSkin.warn)
                    Text("Could not read this container's processes.")
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                    Button("Retry") {
                        loadGeneration &+= 1
                    }
                    .font(.system(size: UIScale.pt(11), weight: .medium))
                }
                .padding(UIScale.pt(16))
            } else if model.processes.isEmpty {
                Text("No processes are running in this container.")
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(UIScale.pt(16))
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(model.processes) { process in
                        HStack(spacing: UIScale.pt(10)) {
                            Text(process.pid)
                                .font(DashSkin.mono(10.5))
                                .frame(width: UIScale.pt(56), alignment: .leading)
                            Text(process.user)
                                .font(.system(size: UIScale.pt(11)))
                                .frame(width: UIScale.pt(80), alignment: .leading)
                            Text(process.command)
                                .font(DashSkin.mono(10.5))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(process.cpu)
                                .font(DashSkin.mono(10.5))
                                .frame(width: UIScale.pt(50), alignment: .trailing)
                            Text(process.memory)
                                .font(DashSkin.mono(10.5))
                                .frame(width: UIScale.pt(50), alignment: .trailing)
                        }
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .padding(.horizontal, UIScale.pt(16))
                        .padding(.vertical, UIScale.pt(5))
                        Divider().opacity(0.15)
                    }
                }
            }
        }
    }

    private var filesView: some View {
        VStack(spacing: 0) {
            HStack(spacing: UIScale.pt(8)) {
                Button {
                    let parent = FileListing.parentPath(of: model.filePath) ?? "/"
                    requestedFilePath = parent
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.edith(.toolbar))
                .disabled(model.filePath == "/")
                Text(model.filePath)
                    .font(DashSkin.mono(11))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, UIScale.pt(16))
            .padding(.vertical, UIScale.pt(7))
            Divider().opacity(0.3)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.filesLoading || !model.filesLoaded && !model.filesFailed {
                        DockerFileRowsSkeleton()
                    } else if model.filesFailed {
                        HStack(spacing: UIScale.pt(8)) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(DashSkin.warn)
                            Text("Could not read this folder.")
                                .font(.system(size: UIScale.pt(12)))
                                .foregroundStyle(DashSkin.inkSoft(dark))
                            Button("Retry") { loadGeneration &+= 1 }
                                .font(.system(size: UIScale.pt(11), weight: .medium))
                        }
                        .padding(UIScale.pt(16))
                    } else if model.files.isEmpty {
                        Text("This folder is empty.")
                            .font(.system(size: UIScale.pt(12)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(UIScale.pt(16))
                    }
                    ForEach(model.files) { entry in
                        HStack(spacing: UIScale.pt(10)) {
                            Image(systemName: entry.isDirectory ? "folder" : "doc")
                                .foregroundStyle(DashSkin.inkFaint(dark))
                                .frame(width: UIScale.pt(15))
                            Text(entry.name)
                                .font(.system(size: UIScale.pt(12)))
                                .foregroundStyle(DashSkin.ink(dark))
                            Spacer(minLength: 0)
                            if !entry.isDirectory {
                                Text(ByteFormatter.string(entry.sizeBytes))
                                    .font(DashSkin.mono(10))
                                    .foregroundStyle(DashSkin.inkFaint(dark))
                            }
                        }
                        .padding(.horizontal, UIScale.pt(16))
                        .padding(.vertical, UIScale.pt(5))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            guard entry.isDirectory else { return }
                            requestedFilePath = entry.path
                        }
                    }
                }
            }
        }
    }
}
