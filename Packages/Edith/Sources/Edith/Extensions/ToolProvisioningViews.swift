import EdithKit
import SwiftUI

struct ToolProvisioningSheet: View {
    let entry: ExtensionRegistryEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ToolProvisioningPanel(
            title: "Setting up \(entry.title)", tools: activeTools,
            continueAction: { dismiss() }
        )
        .frame(width: UIScale.pt(520))
    }

    private var activeTools: [CLIToolSpec] {
        entry.requiredTools.filter { $0.requirement.isActive() }
    }
}

struct ToolProvisioningPanel: View {
    let title: String
    let tools: [CLIToolSpec]
    let continueAction: (() -> Void)?
    @State private var provisioner = ToolProvisioner.shared
    @State private var logExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                Text(title)
                    .font(.system(size: UIScale.pt(17), weight: .semibold))
                Text("You can continue immediately. Setup will keep running in the background.")
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: UIScale.pt(10)) {
                ForEach(tools) { tool in
                    ProvisioningToolRow(tool: tool, state: provisioner.state(for: tool))
                }
            }
            DisclosureGroup("Installation log", isExpanded: $logExpanded) {
                ScrollView {
                    Text(logText)
                        .font(.system(size: UIScale.pt(10.5), design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(UIScale.pt(10))
                }
                .frame(height: UIScale.pt(110))
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
            }
            .font(.system(size: UIScale.pt(10), weight: .medium))
            if let continueAction {
                HStack {
                    Spacer()
                    Button("Continue", action: continueAction)
                        .keyboardShortcut(.defaultAction)
                        .pointerCursor()
                }
            }
        }
        .padding(UIScale.pt(22))
        .onAppear { provisioner.provision(tools) }
    }

    private var logText: String {
        let sections = tools.compactMap { tool -> String? in
            guard let lines = provisioner.logs[tool.id], !lines.isEmpty else { return nil }
            return (["\(tool.displayName):"] + lines).joined(separator: "\n")
        }
        return sections.isEmpty ? "Waiting for output..." : sections.joined(separator: "\n\n")
    }
}

private struct ProvisioningToolRow: View {
    let tool: CLIToolSpec
    let state: CLIToolProvisionState

    var body: some View {
        HStack(alignment: .top, spacing: UIScale.pt(11)) {
            ToolStateIcon(state: state)
                .frame(width: UIScale.pt(20), height: UIScale.pt(20))
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                HStack {
                    Text(tool.displayName)
                        .font(.system(size: UIScale.pt(13), weight: .semibold))
                    Spacer()
                    Text(statusText)
                        .font(.system(size: UIScale.pt(10)))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                }
                Text(tool.why)
                    .settingsCaption()
                if case let .failed(_, instruction) = state {
                    Text(instruction)
                        .settingsCaption()
                        .textSelection(.enabled)
                }
            }
        }
        .padding(UIScale.pt(11))
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
    }

    private var statusText: String {
        switch state {
        case .idle: "Waiting"
        case .checking: "Checking..."
        case let .present(version): version
        case let .installing(logTail): logTail.last ?? "Installing..."
        case .installed: "Installed"
        case let .failed(message, _): message
        }
    }

    private var statusColor: Color {
        switch state {
        case .failed: .red
        case .present, .installed: .green
        default: .secondary
        }
    }
}

private struct ToolStateIcon: View {
    let state: CLIToolProvisionState

    var body: some View {
        switch state {
        case .checking, .installing:
            ProgressView()
                .controlSize(.small)
        case .present, .installed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .idle:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        }
    }
}

struct CLIToolStatusSection: View {
    let tools: [CLIToolSpec]
    let extensionEnabled: Bool
    @State private var provisioner = ToolProvisioner.shared

    var body: some View {
        Section {
            ForEach(tools) { tool in
                HStack(alignment: .top, spacing: UIScale.pt(10)) {
                    ToolStateIcon(state: provisioner.state(for: tool))
                        .frame(width: UIScale.pt(18), height: UIScale.pt(22))
                    VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                        Text(tool.displayName)
                            .fontWeight(.medium)
                        Text(detail(for: tool))
                            .settingsCaption()
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 12)
                    if canInstall(tool) {
                        Button(buttonTitle(for: tool)) { provisioner.provision(tool) }
                            .controlSize(.small)
                            .pointerCursor()
                    }
                }
            }
        } header: {
            Text("Command-line tools")
        } footer: {
            Text(
                extensionEnabled
                    ? "Tools stay installed when the extension is disabled."
                    : "Enable the extension before installing its tools."
            )
        }
        .onAppear {
            for tool in tools { provisioner.check(tool) }
        }
    }

    private func detail(for tool: CLIToolSpec) -> String {
        switch provisioner.state(for: tool) {
        case .idle: tool.why
        case .checking: "Checking availability..."
        case let .present(version): "Installed, \(version)"
        case let .installing(logTail): logTail.last ?? "Installing..."
        case .installed: "Installed and verified"
        case let .failed(message, instruction): "\(message). \(instruction)"
        }
    }

    private func canInstall(_ tool: CLIToolSpec) -> Bool {
        guard extensionEnabled else { return false }
        return switch provisioner.state(for: tool) {
        case .checking, .installing, .present, .installed: false
        case .idle, .failed: true
        }
    }

    private func buttonTitle(for tool: CLIToolSpec) -> String {
        if case .failed = provisioner.state(for: tool) { return "Retry" }
        return "Install"
    }
}
