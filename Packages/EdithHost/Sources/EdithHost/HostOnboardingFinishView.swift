import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostOnboardingInstallView: View {
    @Bindable var model: HostWorkflowOnboardingModel
    let progress: (String) -> Double

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            PageSectionHeader(
                "Installing your tools",
                subtitle: "Edith downloads, verifies and starts only the tools you selected.")
            ForEach(model.selectedEntries) { entry in
                HStack {
                    Image(systemName: entry.symbolName).frame(width: UIScale.pt(24))
                    Text(entry.title)
                    Spacer()
                    switch model.states[entry.id] ?? .waiting {
                    case .waiting: Text("Waiting").foregroundStyle(.secondary)
                    case .installing: Text("Downloading and starting").foregroundStyle(.secondary)
                    case .ready:
                        Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed:
                        Label("Needs retry", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                }.font(.edithText(.callout))
                if case .installing = model.states[entry.id] {
                    ProgressView(value: min(1, max(0, progress(entry.id))))
                }
                if case .failed(let failure) = model.states[entry.id] {
                    Text(failure).font(.edithText(.caption)).foregroundStyle(.orange)
                }
            }
            HStack {
                if model.busy {
                    Button("Cancel setup") { model.cancel() }
                } else {
                    Button("Change selection") { model.back() }
                    Spacer()
                    Button("Retry setup") { model.installSelection() }
                        .buttonStyle(.edith(.primary)).disabled(!model.canInstall)
                }
            }
        }
    }
}

struct HostOnboardingFinishView: View {
    @Bindable var model: HostWorkflowOnboardingModel
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            if model.selected.isEmpty { empty } else { installed }
            Text("Agents can drive any tool through the ed command line and MCP.")
                .font(.edithText(.caption)).foregroundStyle(.secondary)
            HStack {
                Button("View Storage") { model.openStorage() }
                Spacer()
                Button("Start using Edith") { model.dismiss() }.buttonStyle(.edith(.primary))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding.finish")
            }
        }
    }

    private var empty: some View {
        PageEmptyState(
            symbolName: "checkmark.circle", title: "Edith is ready",
            message:
                "No tools yet. Open the marketplace from the sidebar whenever you want to add some, or run setup again from Settings.")
            .frame(minHeight: UIScale.pt(220))
    }

    private var installed: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            Label("You are all set", systemImage: "checkmark.circle.fill")
                .font(.edithText(.title3)).fontWeight(.semibold).foregroundStyle(.green)
            Text("Here is where each tool lives and how to open it.")
                .font(.edithText(.callout)).foregroundStyle(.secondary)
            ForEach(model.selectedEntries) { entry in row(entry) }
        }
    }

    private func row(_ entry: HostExtension) -> some View {
        let pages = model.destinations(for: entry)
        return HStack(alignment: .top, spacing: UIScale.pt(12)) {
            Image(systemName: entry.symbolName).foregroundStyle(DashSkin.accent(dark))
                .frame(width: UIScale.pt(24))
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                Text(entry.title).font(.edithText(.body)).fontWeight(.semibold)
                Text(model.tagline(for: entry)).font(.edithText(.caption))
                    .foregroundStyle(.secondary)
                Text(location(entry, pages: pages)).font(.edithText(.caption))
                    .foregroundStyle(.secondary)
                if let example = entry.guide?.examples.first {
                    Text(example).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            if let page = pages.first {
                Button("Open \(page.title)") { model.open(page: page.id) }
                    .buttonStyle(.edith(.secondary))
                    .accessibilityIdentifier("onboarding.open.\(entry.id)")
            }
        }
        .padding(UIScale.pt(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
    }

    private func location(_ entry: HostExtension, pages: [HostPage]) -> String {
        if !pages.isEmpty {
            return "In the sidebar: " + pages.map(\.title).joined(separator: ", ")
        }
        if !entry.hotkeys.isEmpty { return "Runs in the background. Use its hotkey from anywhere." }
        return "Runs in the background, from the menu bar or the notch."
    }
}
