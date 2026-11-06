import EdithExtensionUI
import EdithHostCore
import ExtensionMarketplace
import SwiftUI

struct HostOnboardingToolsView: View {
    @Bindable var model: HostWorkflowOnboardingModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @State private var expanded: Set<String>?
    private var dark: Bool { scheme == .dark }

    private var sizesMissing: Bool { !model.busy && !model.cost.complete }

    var body: some View {
        let groups = model.groups
        let open = expanded ?? defaultExpanded(groups)
        VStack(alignment: .leading, spacing: UIScale.pt(20)) {
            HostOnboardingStepHeader(
                "Choose your tools",
                subtitle: model.selected.isEmpty
                    ? "Tick the tools you want. Every tool is optional, and you can add more later from Extensions."
                    : "We ticked the tools that fit your workflow. Every tool is optional, and you can add more later from Extensions."
            )
            if groups.isEmpty, !model.busy {
                PageNotice(
                    model.failure
                        ?? "Edith could not load the list of tools. Check your internet connection, then try again.",
                    title: "Tools are unavailable right now", tone: .warning
                ) {
                    EmptyView()
                } actions: {
                    Button("Try again") { model.refreshCatalog() }
                        .accessibilityIdentifier("onboarding.refresh-catalog")
                }
            } else if sizesMissing, !model.selected.isEmpty {
                PageNotice(
                    model.failure
                        ?? "Edith could not check download sizes for every tool. Check your connection, then try again.",
                    title: "Download sizes are unavailable", tone: .warning
                ) {
                    EmptyView()
                } actions: {
                    Button("Try again") { model.refreshCatalog() }
                        .accessibilityIdentifier("onboarding.refresh-sizes")
                }
            } else if let failure = model.failure {
                PageNotice(failure, tone: .warning)
            }
            if groups.isEmpty {
                if model.busy { loadingGroups }
            } else {
                VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                    ForEach(groups, id: \.category) { group in
                        groupSection(group.category, entries: group.entries, open: open)
                    }
                }
                summary
            }
            HostOnboardingFooter(
                back: { model.back() },
                skip: PageAction("Skip tools", identifier: "onboarding.skip-step") {
                    model.skipStep()
                },
                primary: PageAction(
                    model.selected.isEmpty
                        ? "Choose a tool to continue"
                        : "Continue with \(model.selected.count) \(model.selected.count == 1 ? "tool" : "tools")",
                    icon: .arrowRight, identifier: "workflow.install-selection"
                ) { model.continueFromTools() },
                primaryEnabled: model.canInstall, busy: model.busy)
        }
    }

    private var loadingGroups: some View {
        SkeletonGroup {
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                ForEach(0..<3, id: \.self) { index in
                    VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                        HStack(spacing: UIScale.pt(12)) {
                            Color.clear.frame(width: UIScale.pt(20), height: 1)
                            SkeletonBlock(width: 28, height: 28, corner: 8)
                            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                                SkeletonBlock(width: 120, height: 12)
                                SkeletonBlock(width: 64, height: 10)
                            }
                            Spacer(minLength: 0)
                            SkeletonBlock(width: 64, height: 12)
                        }
                        if index == 0 {
                            ForEach(0..<3, id: \.self) { _ in
                                HStack(spacing: UIScale.pt(12)) {
                                    SkeletonBlock(width: 20, height: 20, corner: 5)
                                    SkeletonBlock(width: 28, height: 28, corner: 8)
                                    VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                                        SkeletonBlock(width: 140, height: 11)
                                        SkeletonBlock(width: 280, height: 9)
                                    }
                                    Spacer(minLength: 0)
                                    SkeletonBlock(width: 40, height: 10)
                                }
                            }
                        }
                    }
                    .padding(UIScale.pt(12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hostOnboardingTile()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading tools")
    }

    private func defaultExpanded(_ groups: [(category: String, entries: [HostExtension])])
        -> Set<String>
    {
        let chosen = Set(
            groups.filter { group in group.entries.contains { model.selected.contains($0.id) } }
                .map(\.category))
        if !chosen.isEmpty { return chosen }
        return groups.first.map { [$0.category] } ?? []
    }

    private func groupSection(_ category: String, entries: [HostExtension], open: Set<String>)
        -> some View
    {
        let suite = HostMarketplaceCatalog.suites.first { $0.id == category }
        let isOpen = open.contains(category)
        let chosen = entries.filter { model.selected.contains($0.id) }.count
        let title = suite?.title ?? category.capitalized
        let selectAll = Button(model.groupSelected(category) ? "Select none" : "Select all") {
            model.setGroup(category, selected: !model.groupSelected(category))
        }
        .buttonStyle(.edith(.borderless))
        .foregroundStyle(DashSkin.accentDeep(dark))
        .fixedSize()
        .disabled(model.busy)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                var next = open
                if isOpen { next.remove(category) } else { next.insert(category) }
                expanded = next
            } label: {
                HStack(spacing: UIScale.pt(12)) {
                    EdithIconView(.chevronRight)
                        .font(.system(size: UIScale.pt(10), weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: UIScale.pt(20))
                    PageGuideBadge(
                        icon: suite?.icon ?? .workflowCustom, size: 32,
                        tint: DashSkin.inkSoft(dark))
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        Text(title).font(.edithText(.headline))
                        Text(
                            chosen == 0
                                ? "\(entries.count) tools"
                                : "\(chosen) of \(entries.count) selected"
                        )
                        .font(.edithText(.caption)).foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    selectAll.hidden().accessibilityHidden(true)
                }
            }
            .buttonStyle(.edith(.row))
            .accessibilityLabel(title)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("onboarding.group.\(category)")
            .overlay(alignment: .trailing) {
                selectAll.padding(.trailing, UIScale.pt(HostOnboardingToolsMetrics.headerContent))
            }
            .padding(.horizontal, UIScale.pt(HostOnboardingToolsMetrics.headerInsetX))
            .padding(.vertical, UIScale.pt(HostOnboardingToolsMetrics.headerInsetY))
            if isOpen {
                Divider().padding(.horizontal, UIScale.pt(12))
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    ForEach(entries) { entry in row(entry) }
                }
                .padding(UIScale.pt(4))
            }
        }
        .hostOnboardingTile()
    }

    private func row(_ entry: HostExtension) -> some View {
        Toggle(
            isOn: Binding(
                get: { model.selected.contains(entry.id) },
                set: { _ in model.toggle(entry.id) })
        ) {
            HStack(alignment: .center, spacing: UIScale.pt(12)) {
                HostExtensionIcon(entry: entry, size: 32, tint: DashSkin.inkSoft(dark))
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text(entry.title).font(.edithText(.callout)).fontWeight(.medium)
                        .lineLimit(1)
                    Text(model.tagline(for: entry)).font(.edithText(.caption))
                        .foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                packageNote(entry.id)
                    .frame(minWidth: UIScale.pt(56), alignment: .trailing)
            }
        }
        .toggleStyle(HostOnboardingCheckRowStyle())
        .disabled(model.busy && model.cost.complete)
    }

    @ViewBuilder private func packageNote(_ id: String) -> some View {
        if model.installedIDs.contains(id) {
            Text("Installed").font(.edithText(.caption)).foregroundStyle(.secondary)
        } else if let bytes = model.reviewMetadata(for: id).downloadBytes {
            Text(Self.bytes(bytes)).font(.edithText(.caption))
                .foregroundStyle(.secondary).monospacedDigit()
                .help(model.reviewMetadata(for: id).summary)
                .accessibilityIdentifier("workflow.package-review.\(id)")
        } else if model.busy {
            SkeletonBlock(width: 40, height: 10)
        }
    }

    private var summary: some View {
        let layout =
            compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: UIScale.pt(12)))
            : AnyLayout(HStackLayout(alignment: .center, spacing: UIScale.pt(16)))
        return layout {
            HStack(spacing: UIScale.pt(12)) {
                EdithIconView(.arrowDown)
                    .font(.system(size: UIScale.pt(16)))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                cost
            }
            if !compact { Spacer(minLength: 0) }
            Toggle(
                isOn: Binding(get: { model.icloudBackup }, set: { model.setICloudBackup($0) })
            ) {
                Text("Back up my settings to iCloud").font(.edithText(.callout))
            }
            .toggleStyle(HostOnboardingCheckboxStyle())
            .disabled(model.busy)
            .fixedSize()
        }
        .padding(.horizontal, UIScale.pt(16))
        .padding(.vertical, UIScale.pt(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            DashSkin.paper(dark),
            in: RoundedRectangle(cornerRadius: UIScale.pt(12), style: .continuous))
    }

    @ViewBuilder private var cost: some View {
        if model.selected.isEmpty {
            Text("No tools selected yet").font(.edithText(.callout)).foregroundStyle(.secondary)
        } else if model.cost.complete {
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(
                    "\(Self.bytes(model.cost.downloadBytes)) to download · about \(Self.bytes(model.cost.installedBytes)) on disk"
                )
                .font(.edithText(.callout)).fontWeight(.medium).monospacedDigit()
                if !model.cost.packageIDs.subtracting(model.selected).isEmpty {
                    Text("Includes the tools they depend on.").font(.edithText(.caption))
                        .foregroundStyle(.secondary)
                }
            }
        } else if model.busy {
            HStack(spacing: UIScale.pt(8)) {
                SkeletonBlock(width: 160, height: 12)
                Text("Checking download sizes").font(.edithText(.caption))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } else {
            Text("Download size unknown").font(.edithText(.callout)).foregroundStyle(.secondary)
        }
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

enum HostOnboardingToolsMetrics {
    static let headerPadding = 12.0
    static let headerContent = 9.0
    static let headerContentY = 7.0
    static let headerInsetX = headerPadding - headerContent
    static let headerInsetY = headerPadding - headerContentY
}

struct HostOnboardingCheckRowStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HostOnboardingCheckRow(configuration: configuration)
    }
}

private struct HostOnboardingCheckRow: View {
    let configuration: ToggleStyle.Configuration
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: UIScale.pt(12)) {
                EdithIconView(configuration.isOn ? .checkboxOn : .checkbox)
                    .font(.system(size: UIScale.pt(16)))
                    .foregroundStyle(
                        configuration.isOn ? DashSkin.accent(dark) : DashSkin.lineStrong(dark)
                    )
                    .frame(width: UIScale.pt(20))
                    .accessibilityHidden(true)
                configuration.label
            }
            .padding(.horizontal, UIScale.pt(8))
            .padding(.vertical, UIScale.pt(8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.edithControl)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
        .accessibilityValue(configuration.isOn ? "Selected" : "Not selected")
    }
}

struct HostOnboardingCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HostOnboardingCheckbox(configuration: configuration)
    }
}

private struct HostOnboardingCheckbox: View {
    let configuration: ToggleStyle.Configuration
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: UIScale.pt(8)) {
                EdithIconView(configuration.isOn ? .checkboxOn : .checkbox)
                    .font(.system(size: UIScale.pt(16)))
                    .foregroundStyle(
                        configuration.isOn ? DashSkin.accent(dark) : DashSkin.lineStrong(dark)
                    )
                    .accessibilityHidden(true)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.edithControl)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}
