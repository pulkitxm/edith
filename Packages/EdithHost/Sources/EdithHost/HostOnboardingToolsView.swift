import EdithExtensionUI
import EdithHostCore
import ExtensionMarketplace
import SwiftUI

struct HostOnboardingToolsView: View {
    @Bindable var model: HostWorkflowOnboardingModel
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            PageSectionHeader(
                "Choose your tools",
                subtitle:
                    "Every tool is optional. Tick what you want now and add more later from the marketplace."
            )
            costSummary
            ForEach(model.groups, id: \.category) { group in
                groupSection(group.category, entries: group.entries)
            }
            Toggle(
                "Back up my settings to iCloud",
                isOn: Binding(get: { model.icloudBackup }, set: { model.setICloudBackup($0) })
            ).disabled(model.busy)
            HostOnboardingFooter(
                back: { model.back() },
                skip: PageAction("Skip tools", identifier: "onboarding.skip-step") {
                    model.skipStep()
                },
                primary: PageAction(
                    model.selected.isEmpty
                        ? "Choose a tool to continue"
                        : "Continue with \(model.selected.count) \(model.selected.count == 1 ? "tool" : "tools")",
                    symbolName: "arrow.right", identifier: "workflow.install-selection"
                ) { model.continueFromTools() },
                primaryEnabled: model.canInstall, busy: model.busy
            ) {
                Button("Refresh sizes") { model.refreshCatalog() }.disabled(model.busy)
                    .buttonStyle(.edith(.borderless))
            }
        }
    }

    private func groupSection(_ category: String, entries: [HostExtension]) -> some View {
        let suite = HostMarketplaceCatalog.suites.first { $0.id == category }
        return VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            HStack {
                Label(suite?.title ?? category.capitalized, systemImage: suite?.symbol ?? "square.grid.2x2")
                    .font(.edithText(.subheadline)).fontWeight(.semibold)
                Spacer()
                Button(model.groupSelected(category) ? "Select none" : "Select all") {
                    model.setGroup(category, selected: !model.groupSelected(category))
                }
                .buttonStyle(.edith(.borderless)).disabled(model.busy)
            }
            ForEach(entries) { entry in row(entry) }
        }
    }

    private func row(_ entry: HostExtension) -> some View {
        HStack(spacing: UIScale.pt(12)) {
            Image(systemName: entry.symbolName).foregroundStyle(DashSkin.accent(dark))
                .frame(width: UIScale.pt(24))
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                Text(entry.title).font(.edithText(.body))
                Text(model.tagline(for: entry)).font(.edithText(.caption))
                    .foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(packageNote(entry.id)).font(.edithText(.caption))
                .foregroundStyle(.secondary).monospacedDigit()
                .help(model.reviewMetadata(for: entry.id).summary)
                .accessibilityIdentifier("workflow.package-review.\(entry.id)")
            Toggle(
                entry.title,
                isOn: Binding(
                    get: { model.selected.contains(entry.id) },
                    set: { _ in model.toggle(entry.id) })
            ).labelsHidden().toggleStyle(.checkbox).disabled(model.busy)
        }
        .padding(.vertical, UIScale.pt(4))
    }

    private var costSummary: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            if model.cost.complete {
                Text(
                    "\(bytes(model.cost.downloadBytes)) to download · about \(bytes(model.cost.installedBytes)) on disk"
                ).font(.edithText(.headline)).monospacedDigit()
                if model.cost.packageIDs.subtracting(model.selected).isEmpty == false {
                    Text("Includes required dependencies.").font(.edithText(.caption))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(
                    "Download sizes are unavailable for \(model.cost.unknownIDs.sorted().joined(separator: ", ")). Refresh before installing."
                ).font(.edithText(.callout)).foregroundStyle(DashSkin.warn)
            }
        }
        .padding(UIScale.pt(12)).frame(maxWidth: .infinity, alignment: .leading)
        .background(DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
    }

    private func packageNote(_ id: String) -> String {
        if model.installedIDs.contains(id) { return "Downloaded" }
        return model.reviewMetadata(for: id).downloadBytes.map(bytes) ?? ""
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
