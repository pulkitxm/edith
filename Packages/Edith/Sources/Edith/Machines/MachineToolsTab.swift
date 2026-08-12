import AppKit
import EdithKit
import SwiftUI

struct MachineToolsTab: View {
    @ObservedObject var session: MachineSession
    @ObservedObject var model: MachinesModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.machineConnectionsEnabled) private var connectionsEnabled
    @State private var newForwardLocal = ""
    @State private var newForwardRemote = ""
    @State private var newForwardHost = "localhost"
    @State private var snippetTitle = ""
    @State private var snippetCommand = ""
    @State private var snippetOutput = ""
    @State private var runningSnippet = false
    @State private var message: String?
    @State private var serviceFilter = ""
    @State private var mounting = false

    private var dark: Bool { scheme == .dark }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                if let message {
                    Text(message)
                        .font(.system(size: UIScale.pt(11.5)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .padding(UIScale.pt(10))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            DashSkin.accent(dark).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
                }
                diskCard
                forwardsCard
                snippetsCard
                servicesCard
            }
            .pageContent(compact)
        }
        .task {
            guard connectionsEnabled else { return }
            await session.refreshServices()
            await session.restoreMount()
        }
    }

    private var diskCard: some View {
        SkinCard(
            title: "Disk",
            note: "Mount this machine's whole file system on your Mac and open it in Finder",
            dark: dark
        ) {
            HStack(spacing: UIScale.pt(10)) {
                if let mount = session.mount {
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        Text(mount.mountPoint)
                            .font(DashSkin.mono(11))
                            .foregroundStyle(DashSkin.ink(dark))
                            .lineLimit(1)
                            .truncationMode(.head)
                        HStack(spacing: UIScale.pt(6)) {
                            Circle()
                                .fill(healthColor)
                                .frame(width: UIScale.pt(6), height: UIScale.pt(6))
                            Text(subtitle(for: mount))
                                .font(.system(size: UIScale.pt(10.5)))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if session.isRemounting {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    }
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            URL(fileURLWithPath: mount.mountPoint)
                        ])
                    }
                    .disabled(session.mountHealth != .mounted)
                    .pointerCursor()
                    Button("Unmount") { unmountDisk() }
                        .disabled(mounting || session.isRemounting)
                        .pointerCursor()
                } else {
                    Text(
                        MachineMounts.isAvailable
                            ? MachineMounts.mountPoint(for: session.machine).path
                            : "sshfs is not installed on this Mac"
                    )
                    .font(
                        MachineMounts.isAvailable
                            ? DashSkin.mono(11) : .system(size: UIScale.pt(11.5))
                    )
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .lineLimit(1)
                    .truncationMode(.head)
                    Spacer(minLength: 0)
                    if mounting {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    }
                    Button("Mount") { mountDisk() }
                        .disabled(
                            mounting || !MachineMounts.isAvailable || !session.state.isConnected
                        )
                        .pointerCursor()
                }
            }
        }
    }

    private var healthColor: Color {
        switch session.mountHealth {
        case .mounted: return DashSkin.ok
        case .stale, .gone: return session.isRemounting ? DashSkin.gold : DashSkin.danger
        case nil: return DashSkin.inkFaint(dark)
        }
    }

    private func subtitle(for mount: MachineMount) -> String {
        var parts = [mount.remotePath]
        if mount.isReadOnly { parts.append("read only") }
        if session.isRemounting {
            parts.append("reconnecting…")
        } else if let health = session.mountHealth, health.needsRepair {
            parts.append(health.describes)
        }
        return parts.joined(separator: "  ·  ")
    }

    private func mountDisk() {
        mounting = true
        message = nil
        Task {
            do {
                let landed = try await MachineMounts.mount(
                    machine: session.machine, remotePath: "/")
                message = "Mounted at \(landed.mountPoint)."
            } catch let failure as MachineMountError {
                message = [failure.errorDescription, failure.hint]
                    .compactMap { $0 }.joined(separator: " ")
            } catch {
                message = error.localizedDescription
            }
            await session.restoreMount()
            mounting = false
        }
    }

    private func unmountDisk() {
        mounting = true
        message = nil
        Task {
            do {
                let released = try await MachineMounts.unmount(machine: session.machine)
                message = "Unmounted \(released.mountPoint)."
            } catch {
                message = error.localizedDescription
            }
            await session.restoreMount()
            mounting = false
        }
    }

    private var forwardsCard: some View {
        SkinCard(
            title: "Port forwards",
            note: "Reach a service on this machine at localhost on your Mac", dark: dark
        ) {
            VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                ForEach(model.store.forwards(machineID: session.machine.id)) { forward in
                    HStack(spacing: UIScale.pt(10)) {
                        Circle()
                            .fill(
                                session.activeForwards.contains(forward.id)
                                    ? DashSkin.ok : DashSkin.inkFaint(dark)
                            )
                            .frame(width: UIScale.pt(7), height: UIScale.pt(7))
                        Text(forward.displayName)
                            .font(DashSkin.mono(11.5))
                            .foregroundStyle(DashSkin.ink(dark))
                        Spacer(minLength: 0)
                        if session.activeForwards.contains(forward.id) {
                            Button("Open") {
                                if let url = URL(string: "http://localhost:\(forward.localPort)") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .pointerCursor()
                            .font(.system(size: UIScale.pt(11)))
                        }
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { session.activeForwards.contains(forward.id) },
                                set: { toggleForward(forward, on: $0) })
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .disabled(!session.state.isConnected)
                        Button {
                            model.removeForward(forward)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(HoverButtonStyle())
                        .help("Remove")
                    }
                }
                HStack(spacing: UIScale.pt(8)) {
                    TextField("Local port", text: $newForwardLocal)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: UIScale.pt(90))
                    Image(systemName: "arrow.right")
                        .font(.system(size: UIScale.pt(10)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                    TextField("Remote host", text: $newForwardHost)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: UIScale.pt(130))
                    TextField("Remote port", text: $newForwardRemote)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: UIScale.pt(90))
                    Button("Add") { addForward() }
                        .disabled(Int(newForwardLocal) == nil || Int(newForwardRemote) == nil)
                        .pointerCursor()
                }
            }
        }
    }

    private var snippetsCard: some View {
        SkinCard(title: "Snippets", note: "Saved commands you run often", dark: dark) {
            VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                ForEach(model.store.snippets(machineID: session.machine.id)) { snippet in
                    HStack(spacing: UIScale.pt(10)) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(snippet.title)
                                .font(.system(size: UIScale.pt(12.5), weight: .medium))
                                .foregroundStyle(DashSkin.ink(dark))
                            Text(snippet.command)
                                .font(DashSkin.mono(10))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Button("Run") { run(snippet.command) }
                            .disabled(runningSnippet || !session.state.isConnected)
                            .pointerCursor()
                            .font(.system(size: UIScale.pt(11)))
                        Button {
                            model.removeSnippet(snippet)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(HoverButtonStyle())
                        .help("Remove")
                    }
                }
                HStack(spacing: UIScale.pt(8)) {
                    TextField("Name", text: $snippetTitle)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: UIScale.pt(140))
                    TextField("Command", text: $snippetCommand)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") { saveSnippet() }
                        .disabled(
                            snippetTitle.trimmingCharacters(in: .whitespaces).isEmpty
                                || snippetCommand.trimmingCharacters(in: .whitespaces).isEmpty
                        )
                        .pointerCursor()
                }
                if !snippetOutput.isEmpty {
                    TerminalLogView(
                        log: snippetOutput, theme: DashSkin.sage, height: UIScale.pt(160))
                }
            }
        }
    }

    private var filteredServices: [SystemdService] {
        let trimmed = serviceFilter.trimmingCharacters(in: .whitespaces)
        let base = session.services
        guard !trimmed.isEmpty else { return Array(base.prefix(40)) }
        return base.filter { $0.unit.localizedCaseInsensitiveContains(trimmed) }
    }

    private var servicesCard: some View {
        SkinCard(
            title: "Services", note: session.services.isEmpty ? "systemd not detected" : nil,
            dark: dark
        ) {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                if !session.services.isEmpty {
                    SearchField(placeholder: "Filter services", text: $serviceFilter)
                        .frame(maxWidth: UIScale.pt(240))
                }
                ForEach(filteredServices) { service in
                    HStack(spacing: UIScale.pt(10)) {
                        Circle()
                            .fill(
                                service.isFailed
                                    ? DashSkin.danger
                                    : (service.isRunning ? DashSkin.ok : DashSkin.inkFaint(dark))
                            )
                            .frame(width: UIScale.pt(7), height: UIScale.pt(7))
                        Text(service.displayName)
                            .font(.system(size: UIScale.pt(12)))
                            .foregroundStyle(DashSkin.ink(dark))
                            .lineLimit(1)
                        Text(service.describes)
                            .font(.system(size: UIScale.pt(10.5)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button("Restart") { runService("restart", unit: service.unit) }
                            .pointerCursor()
                            .font(.system(size: UIScale.pt(11)))
                        Button(service.isRunning ? "Stop" : "Start") {
                            runService(service.isRunning ? "stop" : "start", unit: service.unit)
                        }
                        .pointerCursor()
                        .font(.system(size: UIScale.pt(11)))
                    }
                }
            }
        }
    }

    private func addForward() {
        guard let local = Int(newForwardLocal), let remote = Int(newForwardRemote) else { return }
        let host = newForwardHost.trimmingCharacters(in: .whitespaces)
        let forward = PortForward(
            machineID: session.machine.id, localPort: local,
            remoteHost: host.isEmpty ? "localhost" : host, remotePort: remote)
        model.addForward(forward)
        newForwardLocal = ""
        newForwardRemote = ""
        toggleForward(forward, on: true)
    }

    private func toggleForward(_ forward: PortForward, on: Bool) {
        Task {
            if let failure = await session.setForward(forward, active: on) {
                message = failure
            } else {
                message =
                    on
                    ? "localhost:\(forward.localPort) now reaches "
                        + "\(forward.remoteHost):\(forward.remotePort)."
                    : nil
            }
        }
    }

    private func saveSnippet() {
        model.addSnippet(
            CommandSnippet(
                machineID: session.machine.id,
                title: snippetTitle.trimmingCharacters(in: .whitespaces),
                command: snippetCommand.trimmingCharacters(in: .whitespaces)))
        snippetTitle = ""
        snippetCommand = ""
    }

    private func run(_ command: String) {
        runningSnippet = true
        snippetOutput = "$ \(command)\n"
        Task {
            let result = await session.runCommand(command, timeout: 120)
            runningSnippet = false
            switch result {
            case let .success(output): snippetOutput += output
            case let .failure(error): snippetOutput += error.localizedDescription
            }
        }
    }

    private func runService(_ action: String, unit: String) {
        Task {
            let machineID = session.machine.id
            let stdin = SudoPassword.stdin(machineID: machineID)
            let result = await session.runCommand(
                ServiceCommands.action(action, unit: unit, withSudoPassword: stdin != nil),
                stdin: stdin, timeout: 60)
            if case let .failure(error) = result {
                message = PowerOutcome.explain(error)
            } else {
                message = "\(unit) \(action)ed."
            }
            await session.refreshServices()
        }
    }
}
