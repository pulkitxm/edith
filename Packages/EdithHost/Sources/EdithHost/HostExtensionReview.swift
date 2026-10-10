import EdithExtensionUI
import EdithHostCore
import ExtensionMarketplace
import SwiftUI

struct HostExtensionReview: View {
    @Bindable var marketplace: HostMarketplace
    let suites: HostSuiteSelection
    let entry: HostExtension
    let presenter: (any HostExtensionContentPresenting)?
    let open: (() -> Void)?
    let done: () -> Void
    @State private var reviewed: ExtensionPackage?
    @State private var task: Task<Void, Never>?
    @State private var notice: String?

    init(
        marketplace: HostMarketplace, suites: HostSuiteSelection, entry: HostExtension,
        presenter: (any HostExtensionContentPresenting)?, open: (() -> Void)?,
        done: @escaping () -> Void
    ) {
        self.marketplace = marketplace; self.suites = suites; self.entry = entry
        self.presenter = presenter; self.open = open; self.done = done
        _reviewed = State(initialValue: marketplace.available[entry.id])
    }

    private var active: Bool { marketplace.surfaceAvailability.activeIDs.contains(entry.id) }
    private var installed: Bool { marketplace.installed[entry.id] != nil }
    private var busy: Bool { task != nil || marketplace.operationID != nil || suites.working }
    private var pending: Bool {
        marketplace.pendingRemovalIDs.contains(entry.id)
            || marketplace.sessions.pendingDisableIDs.contains(entry.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(entry.title).font(.edithText(.headline)).accessibilityAddTraits(.isHeader)
                Spacer()
                if active, HostNavigationCatalog.route(extensionID: entry.id) != nil, let open {
                    Button("Open", action: open).buttonStyle(.edith(.secondary)).disabled(busy)
                }
                if installed, !pending {
                    Button(active ? "Disable" : "Enable") {
                        perform { await suites.select(entry, enabled: !active) }
                    }.buttonStyle(.edith(.secondary)).disabled(busy)
                }
            }.padding(.horizontal, UIScale.pt(28)).padding(.vertical, UIScale.pt(18))
            Divider()
            if installed, !pending,
                HostExtensionSettingsPolicy.canPresent(id: entry.id, active: active)
            {
                HostExtensionContent(
                    marketplace: marketplace, extensionID: entry.id, location: "settings",
                    section: "extension", presenter: presenter, openMarketplace: done)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                        Text(HostMarketplaceCatalog.subtitles[entry.id] ?? entry.title)
                            .font(.edithText(.callout))
                        let sizes = HostMarketplacePackageSummary(
                            candidate: reviewed ?? marketplace.installed[entry.id],
                            downloadedVersions: marketplace.installedVersions[entry.id] ?? [])
                        if let estimate = sizes.estimate {
                            Text(estimate).font(.edithText(.callout))
                        }
                        if let downloaded = sizes.downloaded {
                            Text(downloaded).font(.edithText(.caption)).foregroundStyle(.secondary)
                        }
                        if !(entry.requiredPermissions + entry.optionalPermissions).isEmpty {
                            HostPermissionInfoButton(
                                permissions: entry.requiredPermissions + entry.optionalPermissions)
                        }
                        if !installed, !pending {
                            Text(
                                "New downloads stay disabled until you choose Enable. Updates preserve your previous enabled state."
                            )
                            .font(.edithText(.caption)).foregroundStyle(.secondary)
                            if reviewed == nil {
                                Text(
                                    "Verified download information is unavailable. Refresh to review the package."
                                )
                                .font(.edithText(.callout))
                                Button("Refresh") { refresh() }.buttonStyle(.edith(.secondary))
                                    .disabled(busy)
                            } else {
                                Button("Download reviewed package") { download() }
                                    .buttonStyle(.edith(.primary)).disabled(busy)
                            }
                        } else if pending {
                            Text(
                                "Cleanup is pending. Finish removal or retry disable in Extensions."
                            )
                            .font(.edithText(.callout))
                        } else if HostExtensionSettingsPolicy.policy(for: entry.id) == .active {
                            Text("Enable this extension to open its settings.").font(
                                .edithText(.callout))
                        } else if let route = HostNavigationCatalog.route(extensionID: entry.id) {
                            Text(
                                "Open \(HostNavigationCatalog.pages.first { $0.id == route.page }?.title ?? entry.title) from the sidebar to use this extension."
                            )
                            .font(.edithText(.callout))
                        } else {
                            Text(
                                "This extension's controls are available from its menu or shortcut."
                            )
                            .font(.edithText(.callout))
                        }
                        if let notice {
                            Text(notice).font(.edithText(.caption)).foregroundStyle(.orange)
                        }
                        if let error = marketplace.error {
                            Text(error).font(.edithText(.caption)).foregroundStyle(.red)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(UIScale.pt(28))
                }
            }
            Divider()
            HStack {
                if busy { LoadingIndicator().frame(width: UIScale.pt(16), height: UIScale.pt(16)) }
                Spacer();
                Button("Done", action: done).keyboardShortcut(.defaultAction).disabled(busy)
            }.padding(.horizontal, UIScale.pt(18)).padding(.vertical, UIScale.pt(12)).background(
                .bar)
        }
        .frame(width: PresentationMetrics.width(560), height: PresentationMetrics.height(620))
        .interactiveDismissDisabled(busy)
        .onDisappear { task?.cancel() }
    }

    private func perform(_ action: @escaping @MainActor () async -> Void) {
        guard !busy else { return }
        task = Task {
            defer { task = nil }
            await action()
        }
    }
    private func refresh() {
        perform {
            await marketplace.checkForUpdates()
            guard !Task.isCancelled else { return }
            reviewed = marketplace.available[entry.id]
        }
    }
    private func download() {
        guard let reviewed else { return }
        perform {
            await marketplace.download(id: entry.id, expectedPackage: reviewed)
            guard !Task.isCancelled else { return }
            if marketplace.available[entry.id] != reviewed {
                self.reviewed = marketplace.available[entry.id]
                notice = "The package changed. Review its version and size before downloading."
            }
        }
    }
}
