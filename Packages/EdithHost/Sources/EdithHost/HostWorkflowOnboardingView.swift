import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostWorkflowOnboardingView: View {
    @Bindable var model: HostWorkflowOnboardingModel
    let progress: () -> Double
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @State private var permissions = HostPermissions()
    @State private var permissionTask: Task<Void, Never>?
    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(18)) {
            PageSectionHeader(title, subtitle: detail)
            switch model.stage {
            case .workflows: workflowChoices
            case .review: selectionReview
            case .installing: installProgress
            case .finished: finished
            }
            if let failure = model.failure {
                Text(failure).font(.edithText(.callout)).foregroundStyle(.orange).textSelection(
                    .enabled)
            }
        }
        .padding(UIScale.pt(20))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(14)))
        .overlay(RoundedRectangle(cornerRadius: UIScale.pt(14)).strokeBorder(DashSkin.line(dark)))
        .pageTask {
            if model.stage == .workflows, !model.busy { model.refreshCatalog() }
            await permissions.refresh()
        }
        .onDisappear {
            permissionTask?.cancel(); permissionTask = nil; model.cancel()
        }
    }

    private var title: String {
        switch model.stage {
        case .workflows: "Make Edith work for you"
        case .review: "Choose your tools"
        case .installing: "Setting up your workflow"
        case .finished: "Your workflow is ready"
        }
    }
    private var detail: String {
        switch model.stage {
        case .workflows:
            "What do you use your Mac for? Pick a starting point and choose the tools you want."
        case .review:
            "Every extension is optional. Review the download and storage sizes before installing."
        case .installing: "Edith downloads, verifies and starts only the extensions you selected."
        case .finished:
            "Your tools are ready. Open feature pages from the sidebar and manage helper tools in Extensions."
        }
    }

    private var workflowChoices: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: compact ? 200 : 240), spacing: UIScale.pt(12))
                ], spacing: UIScale.pt(12)
            ) {
                ForEach(HostWorkflow.allCases) { workflow in
                    Button {
                        model.choose(workflow)
                    } label: {
                        HStack(alignment: .top, spacing: UIScale.pt(12)) {
                            Image(systemName: workflow.symbol).font(.system(size: UIScale.pt(21)))
                                .foregroundStyle(DashSkin.accent(dark)).frame(width: UIScale.pt(28))
                            VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                                Text(workflow.title).font(.edithText(.headline))
                                Text(workflow.detail).font(.edithText(.callout)).foregroundStyle(
                                    .secondary
                                ).multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                        }.frame(
                            maxWidth: .infinity, minHeight: UIScale.pt(72), alignment: .topLeading
                        ).padding(UIScale.pt(12))
                    }.buttonStyle(.edith(.secondary)).disabled(model.busy)
                }
            }
            HStack {
                Button("Restore my iCloud selection") { model.restoreSelection() }.disabled(
                    model.busy)
                if model.busy {
                    LoadingIndicator().frame(width: UIScale.pt(16), height: UIScale.pt(16))
                }
                Spacer()
                Button(model.skipTitle) { model.skip() }.disabled(model.busy)
            }
        }
    }

    private var selectionReview: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            costSummary
            permissionReview
            Toggle(
                "Back up my settings to iCloud",
                isOn: Binding(get: { model.icloudBackup }, set: { model.setICloudBackup($0) })
            ).disabled(model.busy)
            ForEach(model.entries) { entry in
                HStack(spacing: UIScale.pt(12)) {
                    Image(systemName: entry.symbolName).foregroundStyle(DashSkin.accent(dark))
                        .frame(width: UIScale.pt(24))
                    VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                        Text(entry.title).font(.edithText(.body))
                        Text(HostMarketplaceCatalog.subtitles[entry.id] ?? entry.category).font(
                            .edithText(.caption)
                        ).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.installedIDs.contains(entry.id) {
                        Text("Downloaded").font(.edithText(.caption)).foregroundStyle(.secondary)
                    }
                    Toggle(
                        entry.title,
                        isOn: Binding(
                            get: { model.selected.contains(entry.id) },
                            set: { _ in model.toggle(entry.id) })
                    ).labelsHidden().toggleStyle(.checkbox).disabled(model.busy)
                }.padding(.vertical, UIScale.pt(4))
            }
            HStack {
                Button("Back") { model.back() }.disabled(model.busy)
                Button("Refresh sizes") { model.refreshCatalog() }.disabled(model.busy)
                Spacer()
                Button("Install \(model.selected.count) extensions") { model.installSelection() }
                    .buttonStyle(.edith(.primary)).disabled(!model.canInstall)
            }
        }
    }

    private var permissionReview: some View {
        let selected = model.entries.filter { model.selected.contains($0.id) }
        let required = Set(selected.flatMap(\.requiredPermissions))
        let optional = Set(selected.flatMap(\.optionalPermissions)).subtracting(required)
        return Group {
            if !required.isEmpty || !optional.isEmpty {
                DisclosureGroup("Permissions for your selection") {
                    ForEach(
                        HostPermission.allCases.filter {
                            required.contains($0) || optional.contains($0)
                        }, id: \.self
                    ) { permission in
                        HStack {
                            Text(permission.displayName)
                            HostPermissionInfoButton(permission)
                            Text(required.contains(permission) ? "Required" : "Optional")
                                .foregroundStyle(.secondary)
                            Spacer()
                            if permissions.granted[permission] == true {
                                Label("Granted", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else if permission.grantsOnFirstUse {
                                Text("Asked when needed").foregroundStyle(.secondary)
                            } else {
                                Button("Grant") {
                                    permissionTask?.cancel()
                                    permissionTask = Task { await permissions.request(permission) }
                                }.disabled(model.busy || permissions.requesting != nil)
                            }
                        }.font(.edithText(.callout)).padding(.vertical, UIScale.pt(4))
                    }
                    Text(
                        "Grant what you are comfortable with. Some tools need permission before they can start."
                    ).font(.edithText(.caption)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var costSummary: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            if model.cost.complete {
                Text(
                    "\(bytes(model.cost.downloadBytes)) download · \(bytes(model.cost.installedBytes)) unpacked package contents"
                ).font(.edithText(.headline))
                if model.cost.packageIDs.subtracting(model.selected).isEmpty == false {
                    Text("Includes required extension dependencies.").font(.edithText(.caption))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(
                    "Download sizes are unavailable for \(model.cost.unknownIDs.sorted().joined(separator: ", ")). Refresh before installing."
                ).font(.edithText(.callout)).foregroundStyle(.orange)
            }
            Text("Already downloaded extensions do not add to this download.").font(
                .edithText(.caption)
            ).foregroundStyle(.secondary)
            Text(
                "Package sizes estimate additional contents. Actual disk use can differ on APFS. Storage measures the app, packages, cache and retained data."
            ).font(.edithText(.caption)).foregroundStyle(.secondary)
        }.padding(UIScale.pt(12)).frame(maxWidth: .infinity, alignment: .leading).background(
            DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
    }

    private var installProgress: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            ForEach(model.entries.filter { model.selected.contains($0.id) }) { entry in
                HStack {
                    Text(entry.title)
                    Spacer()
                    switch model.states[entry.id] ?? .waiting {
                    case .waiting: Text("Waiting").foregroundStyle(.secondary)
                    case .installing: Text("Downloading and starting").foregroundStyle(.secondary)
                    case .ready:
                        Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed:
                        Label("Needs retry", systemImage: "exclamationmark.circle").foregroundStyle(
                            .orange)
                    }
                }.font(.edithText(.callout))
                if case .installing = model.states[entry.id] {
                    ProgressView(value: min(1, max(0, progress())))
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
                    Button("Retry setup") { model.installSelection() }.buttonStyle(.edith(.primary))
                        .disabled(!model.canInstall)
                }
            }
        }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            Label(
                model.selected.isEmpty
                    ? "Start with Home. Add tools whenever you need them."
                    : "\(model.selected.count) selected extensions are ready.",
                systemImage: "checkmark.circle.fill"
            ).foregroundStyle(.green)
            HStack {
                Button("Go to Home") { model.dismiss() }.buttonStyle(.edith(.primary))
                Button("View Storage") { model.openStorage() }
            }
        }
    }
    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
