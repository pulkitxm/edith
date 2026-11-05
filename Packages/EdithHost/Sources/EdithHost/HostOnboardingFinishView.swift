import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostOnboardingInstallView: View {
    @Bindable var model: HostWorkflowOnboardingModel
    let progress: (String) -> Double
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        let entries = model.selectedEntries
        let ready = entries.filter { model.states[$0.id] == .ready }.count
        let failed = !model.busy && ready < entries.count
        VStack(alignment: .leading, spacing: UIScale.pt(20)) {
            HostOnboardingStepHeader(
                failed ? "Some tools did not finish" : "Installing your tools",
                subtitle: failed
                    ? "The tools that finished are ready to use. Retry the rest, or change your selection."
                    : "Edith downloads, checks and starts each tool. This usually takes a few seconds."
            )
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                HStack {
                    Text("\(ready) of \(entries.count) ready").font(.edithText(.callout))
                        .fontWeight(.medium).monospacedDigit()
                    Spacer()
                }
                LoadingProgress(
                    value: Double(ready), total: Double(max(entries.count, 1)),
                    tint: failed ? DashSkin.warn : nil)
            }
            if let failure = model.failure,
                !entries.contains(where: {
                    if case .failed = model.states[$0.id] { return true } else { return false }
                })
            {
                PageNotice(failure, tone: .warning)
            }
            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider().padding(.leading, UIScale.pt(56)) }
                    row(entry)
                }
            }
            .hostOnboardingTile()
            if model.busy {
                HostOnboardingFooter(
                    primary: PageAction("Cancel setup", identifier: "onboarding.cancel") {
                        model.cancel()
                    }, primaryRole: .secondary)
            } else {
                HostOnboardingFooter(
                    primary: PageAction(
                        "Retry setup", icon: .refresh, identifier: "onboarding.retry"
                    ) { model.installSelection() },
                    primaryEnabled: model.canInstall
                ) {
                    Button("Change selection") { model.back() }
                        .buttonStyle(.edith(.secondary))
                        .accessibilityIdentifier("onboarding.change-selection")
                }
            }
        }
    }

    private func row(_ entry: HostExtension) -> some View {
        let state = model.states[entry.id] ?? .waiting
        return HStack(alignment: .center, spacing: UIScale.pt(12)) {
            HostExtensionIcon(entry: entry, size: 32)
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                Text(entry.title).font(.edithText(.callout)).fontWeight(.medium)
                switch state {
                case .installing:
                    LoadingProgress(value: min(1, max(0, progress(entry.id))))
                        .frame(maxWidth: UIScale.pt(240))
                case .failed(let message):
                    Text(message).font(.edithText(.caption)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .waiting, .ready:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            status(state, id: entry.id)
        }
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(12))
        .frame(minHeight: UIScale.pt(56))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func status(_ state: HostWorkflowOnboardingModel.InstallState, id: String)
        -> some View
    {
        Group {
            switch state {
            case .waiting:
                Label("Waiting", edith: .clock).foregroundStyle(.secondary)
            case .installing:
                Text("\(Int((min(1, max(0, progress(id)))) * 100))%")
                    .foregroundStyle(.secondary).monospacedDigit()
            case .ready:
                Label("Ready", edith: .success).foregroundStyle(DashSkin.ok)
            case .failed:
                Label("Needs retry", edith: .alert)
                    .foregroundStyle(DashSkin.warn)
            }
        }
        .font(.edithText(.caption)).fontWeight(.medium)
        .fixedSize()
    }
}

private enum HostOnboardingFinishRow {
    static let icon = 32.0
    static let inset = 12.0
    static let placementWidth = 320.0
    static let actionWidth = 64.0
    static var dividerInset: Double { inset + icon + inset }
}

struct HostOnboardingFinishView: View {
    @Bindable var model: HostWorkflowOnboardingModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    private var dark: Bool { scheme == .dark }

    var body: some View {
        if model.selected.isEmpty { empty } else { installed }
    }

    private var empty: some View {
        VStack(spacing: UIScale.pt(20)) {
            PageGuideBadge(icon: .brand, size: compact ? 40 : 60)
            VStack(spacing: UIScale.pt(8)) {
                Text("Edith is ready").font(.edithText(.title2)).fontWeight(.bold)
                    .accessibilityAddTraits(.isHeader)
                Text(
                    "You have not added any tools yet. Open Extensions in the sidebar whenever you want some, or run setup again from Settings."
                )
                .font(.edithText(.callout)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: UIScale.pt(440))
            }
            finishButton
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, UIScale.pt(compact ? 24 : 32))
    }

    private var installed: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(20)) {
            HStack(alignment: .center, spacing: UIScale.pt(16)) {
                PageGuideBadge(icon: .brand, size: compact ? 40 : 60).flushLeading()
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text("You are all set").font(.edithText(.title2)).fontWeight(.bold)
                        .accessibilityAddTraits(.isHeader)
                    Text(
                        "\(model.selected.count) \(model.selected.count == 1 ? "tool is" : "tools are") ready. Here is where to find each one."
                    )
                    .font(.edithText(.callout)).foregroundStyle(DashSkin.inkSoft(dark))
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(model.selectedEntries.enumerated()), id: \.element.id) {
                    index, entry in
                    if index > 0 {
                        Divider().padding(
                            .leading, UIScale.pt(HostOnboardingFinishRow.dividerInset))
                    }
                    row(entry)
                }
            }
            .hostOnboardingTile()
            Label(
                "Agents can use these tools too, through the ed command line and MCP.",
                edith: .terminal
            )
            .font(.edithText(.caption)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HostOnboardingFooter(
                primary: PageAction("Start using Edith", identifier: "onboarding.finish") {
                    model.dismiss()
                }
            ) {
                Button("View storage") { model.openStorage() }
                    .buttonStyle(.edith(.borderless))
                    .foregroundStyle(DashSkin.accentDeep(dark))
                    .help("See how much disk space your tools use.")
                    .accessibilityIdentifier("onboarding.storage")
            }
        }
    }

    private var finishButton: some View {
        Button("Start using Edith") { model.dismiss() }
            .buttonStyle(.edith(.primary))
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("onboarding.finish")
    }

    private func row(_ entry: HostExtension) -> some View {
        let pages = model.destinations(for: entry)
        return HStack(alignment: .center, spacing: UIScale.pt(12)) {
            HostExtensionIcon(entry: entry, size: HostOnboardingFinishRow.icon)
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(entry.title).font(.edithText(.headline))
                Text(model.tagline(for: entry)).font(.edithText(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if compact { placement(entry, pages: pages) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                placement(entry, pages: pages)
                    .frame(
                        width: UIScale.pt(HostOnboardingFinishRow.placementWidth),
                        alignment: .leading)
            }
            ZStack(alignment: .trailing) {
                Color.clear.frame(
                    width: UIScale.pt(HostOnboardingFinishRow.actionWidth), height: 1)
                if let page = pages.first {
                    Button("Open") { model.open(page: page.id) }
                        .buttonStyle(.edith(.secondary))
                        .fixedSize()
                        .accessibilityLabel("Open \(page.title)")
                        .accessibilityIdentifier("onboarding.open.\(entry.id)")
                }
            }
        }
        .padding(.horizontal, UIScale.pt(HostOnboardingFinishRow.inset))
        .padding(.vertical, UIScale.pt(HostOnboardingFinishRow.inset))
        .frame(minHeight: UIScale.pt(56))
    }

    private func placement(_ entry: HostExtension, pages: [HostPage]) -> some View {
        Label(location(entry, pages: pages), edith: locationIcon(entry, pages: pages))
            .font(.edithText(.caption)).foregroundStyle(DashSkin.inkSoft(dark))
            .lineLimit(2)
    }

    private func location(_ entry: HostExtension, pages: [HostPage]) -> String {
        if !pages.isEmpty {
            return "In the sidebar under " + pages.map(\.title).joined(separator: ", ")
        }
        if !entry.hotkeys.isEmpty { return "Runs in the background. Use its hotkey anywhere." }
        return "Runs in the background, from the menu bar or the notch."
    }

    private func locationIcon(_ entry: HostExtension, pages: [HostPage]) -> EdithIcon {
        if !pages.isEmpty { return .sidebarLeft }
        if !entry.hotkeys.isEmpty { return .keyboard }
        return .menuBar
    }
}
