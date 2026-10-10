import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import SwiftUI

enum HostMarketplaceKeys {
    static let expandedExtension = "extensionsExpand"
}

struct MarketplacePage: View {
    @Bindable var marketplace: HostMarketplace
    var presenter: (any HostExtensionContentPresenting)? = nil
    @State private var search = ""
    @State private var category = "all"
    @State private var selected: HostExtension?
    @State private var suites: HostSuiteSelection
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(marketplace: HostMarketplace, presenter: (any HostExtensionContentPresenting)? = nil) {
        self.marketplace = marketplace; self.presenter = presenter
        _suites = State(
            initialValue: HostSuiteSelection(
                marketplace: marketplace,
                defaults: UserDefaults(suiteName: marketplace.identity.defaultsSuite)!))
    }

    private var filtered: [HostExtension] {
        HostMarketplaceCatalog.filter(marketplace.entries, query: search, category: category)
    }
    private var dark: Bool { scheme == .dark }
    private var busy: Bool { marketplace.operationID != nil || suites.working }

    var body: some View {
        PageWorkspace {
            PageHeader("Extensions") {
                Button("Check for Updates") { Task { await marketplace.checkForUpdates() } }
                    .buttonStyle(.edith(.secondary)).disabled(busy)
            } accessory: {
                SearchField(placeholder: "Search extensions", text: $search, typeAhead: true)
                    .accessibilityLabel("Find extensions")
                HostPageTabPicker(
                    title: "Extension category", selection: $category,
                    options: ["all"] + HostMarketplaceCatalog.suites.map(\.id),
                    label: { id in
                        HostMarketplaceCatalog.suites.first { $0.id == id }?.title ?? "All"
                    })
                if let error = marketplace.error {
                    Text(error).foregroundStyle(.red).font(.edithText(.callout))
                }
                if marketplace.offline {
                    Text("You are offline. Installed extensions are still available.")
                        .foregroundStyle(.secondary).font(.edithText(.callout))
                }
            }
        } content: {
            ScrollViewReader { proxy in
                ScrollView {
                    if filtered.isEmpty {
                        ContentUnavailableView {
                            Label(
                                search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? "No abilities available" : "No abilities found",
                                systemImage: "magnifyingglass")
                        } description: {
                            Text(
                                search.isEmpty
                                    ? "This suite has no abilities available."
                                    : "No ability matches \"\(search.trimmingCharacters(in: .whitespacesAndNewlines))\". Try another search."
                            )
                        }.frame(maxWidth: .infinity, minHeight: UIScale.pt(240))
                    } else {
                        LazyVStack(alignment: .leading, spacing: UIScale.pt(22)) {
                            ForEach(HostMarketplaceCatalog.suites) { suite in
                                let entries = filtered.filter { $0.category == suite.id }
                                if !entries.isEmpty {
                                    VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                                        suiteHeader(suite, entries: entries)
                                        LazyVGrid(
                                            columns: PageMetrics.cardColumns(
                                                compact,
                                                minimum: 340, spacing: 14, alignment: .top),
                                            spacing: UIScale.pt(14)
                                        ) {
                                            ForEach(entries) { entry in card(entry).id(entry.id) }
                                        }
                                    }
                                }
                            }
                            Toggle(
                                "Automatically update installed extensions",
                                isOn: $marketplace.automaticallyUpdatesExtensions
                            )
                            .font(.edithText(.callout))
                        }
                    }
                }.pageContent(compact).scrollIndicators(.automatic)
                    .onAppear { handleDeepLink(proxy) }
            }
        }
        .navigationTitle("Extensions")
        .animation(Motion.animation(Motion.snap, reduceMotion: reduceMotion), value: category)
        .edithSheet(item: $selected) { entry in detail(entry) }
    }

    private func suiteHeader(_ suite: HostMarketplaceSuite, entries: [HostExtension]) -> some View {
        let enabled = suites.enabled(suite)
        let onCount = entries.filter { marketplace.surfaceAvailability.activeIDs.contains($0.id) }
            .count
        return HStack(alignment: .center, spacing: UIScale.pt(10)) {
            Image(systemName: suite.symbol).font(.system(size: UIScale.pt(13), weight: .semibold))
                .foregroundStyle(enabled ? DashSkin.accent(dark) : DashSkin.inkFaint(dark))
                .frame(width: UIScale.pt(18))
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(suite.title).font(.system(size: UIScale.pt(14), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                Text(suite.subtitle).font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkSoft(dark)).lineLimit(1)
            }.layoutPriority(1)
            Rectangle().fill(DashSkin.line(dark)).frame(height: UIScale.pt(1)).frame(
                minWidth: UIScale.pt(24))
            Text(enabled ? "\(onCount) of \(entries.count) on" : "off").font(
                DashSkin.mono(10, weight: .medium)
            )
            .foregroundStyle(enabled ? DashSkin.accent(dark) : DashSkin.inkFaint(dark))
            .padding(.horizontal, UIScale.pt(7)).padding(.vertical, UIScale.pt(3))
            .background(
                (enabled ? DashSkin.accent(dark) : DashSkin.inkFaint(dark)).opacity(0.12),
                in: Capsule()
            ).fixedSize()
            Toggle(
                "",
                isOn: Binding(
                    get: { suites.enabled(suite) },
                    set: { value in
                        Task { await suites.setEnabled(value, suite: suite) }
                    })
            ).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(DashSkin.accent(dark))
                .disabled(busy).accessibilityLabel("\(suite.title) suite enabled")
        }
    }

    private func card(_ entry: HostExtension) -> some View {
        HostMarketplaceCard(
            entry: entry, dark: dark,
            active: marketplace.surfaceAvailability.activeIDs.contains(entry.id),
            subtitle: HostMarketplaceCatalog.subtitles[entry.id] ?? entry.title,
            open: { selected = entry },
            enabled: Binding(
                get: { marketplace.surfaceAvailability.activeIDs.contains(entry.id) },
                set: { value in Task { await suites.select(entry, enabled: value) } }),
            toggleDisabled: marketplace.installed[entry.id] == nil
                || marketplace.sessions.pendingDisableIDs.contains(entry.id)
        ) {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                Text(status(entry)).font(.edithText(.caption)).foregroundStyle(.secondary)
                if let package = marketplace.available[entry.id] ?? marketplace.installed[entry.id]
                {
                    Text(
                        "\(ByteCountFormatter.string(fromByteCount: package.downloadBytes, countStyle: .file)) download · \(ByteCountFormatter.string(fromByteCount: package.installedBytes, countStyle: .file)) installed"
                    )
                    .font(.edithText(.caption2)).foregroundStyle(.secondary)
                }
                if marketplace.sessions.pendingDisableIDs.contains(entry.id) {
                    Text(
                        "Cleanup is still pending. Home and Notch cards are inactive. System resources may remain until cleanup or macOS approval finishes."
                    )
                    .font(.edithText(.caption)).foregroundStyle(.secondary)
                }
                controls(entry)
            }
        }.disabled(busy)
    }

    private func status(_ entry: HostExtension) -> String {
        if marketplace.pendingRemovalIDs.contains(entry.id) { return "Removal pending" }
        if marketplace.sessions.pendingDisableIDs.contains(entry.id),
            marketplace.installed[entry.id] == nil
        {
            return "Disable pending · Needs a compatible update"
        }
        if let package = marketplace.installed[entry.id] {
            if marketplace.sessions.pendingDisableIDs.contains(entry.id) {
                return "Disable pending · \(package.version)"
            }
            return
                "\(marketplace.sessions.states[entry.id] == .active ? "Enabled" : "Disabled") · \(package.version)"
        }
        return marketplace.installedVersions[entry.id]?.isEmpty == false
            ? "Needs a compatible update" : "Not installed"
    }

    @ViewBuilder private func controls(_ entry: HostExtension) -> some View {
        HStack(spacing: UIScale.pt(8)) {
            if marketplace.operationID == entry.id {
                LoadingProgress(value: marketplace.progress).frame(width: UIScale.pt(90))
                    .accessibilityLabel("Working on \(entry.title)")
            } else if marketplace.installed[entry.id] != nil {
                if marketplace.updateAvailable(id: entry.id) {
                    Button("Update") { Task { await marketplace.download(id: entry.id) } }
                }
                if marketplace.sessions.pendingDisableIDs.contains(entry.id) {
                    Button("Retry disable") { Task { await suites.select(entry, enabled: false) } }
                    Button("Enable instead") { Task { await suites.select(entry, enabled: true) } }
                } else if marketplace.sessions.states[entry.id] == .active {
                    Button("Open") { selected = entry }
                    Button("Disable") { Task { await suites.select(entry, enabled: false) } }
                } else {
                    Button("Enable") { Task { await suites.select(entry, enabled: true) } }
                }
            } else if !marketplace.pendingRemovalIDs.contains(entry.id) {
                Button(
                    marketplace.installedVersions[entry.id]?.isEmpty == false
                        ? "Update" : "Download"
                ) {
                    Task { await marketplace.download(id: entry.id) }
                }
            }
            if marketplace.operationID != entry.id,
                marketplace.installedVersions[entry.id]?.isEmpty == false
            {
                Button("Remove") { Task { await marketplace.remove(id: entry.id) } }
            }
        }.buttonStyle(.edith(.secondary))
    }

    private func detail(_ entry: HostExtension) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(entry.title).font(.edithText(.headline)).accessibilityAddTraits(.isHeader)
                Spacer(); controls(entry)
            }.padding(.horizontal, UIScale.pt(28)).padding(.vertical, UIScale.pt(18))
            Divider()
            HostExtensionContent(
                marketplace: marketplace, extensionID: entry.id, location: "settings",
                section: "extension", presenter: presenter, openMarketplace: { selected = nil })
            Divider()
            HStack {
                Spacer(); Button("Done") { selected = nil }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, UIScale.pt(18)).padding(.vertical, UIScale.pt(12)).background(
                .bar)
        }.frame(width: PresentationMetrics.width(560), height: PresentationMetrics.height(620))
    }

    private func handleDeepLink(_ proxy: ScrollViewProxy) {
        let defaults = UserDefaults(suiteName: marketplace.identity.defaultsSuite)!
        guard let id = defaults.string(forKey: HostMarketplaceKeys.expandedExtension),
            let entry = marketplace.entries.first(where: { $0.id == id })
        else { return }
        defaults.removeObject(forKey: HostMarketplaceKeys.expandedExtension); search = "";
        category = "all"
        DispatchQueue.main.async {
            proxy.scrollTo(entry.id, anchor: .center); selected = entry
        }
    }
}

private struct HostMarketplaceCard<Controls: View>: View {
    let entry: HostExtension
    let dark: Bool
    let active: Bool
    let subtitle: String
    let open: () -> Void
    let enabled: Binding<Bool>
    let toggleDisabled: Bool
    @ViewBuilder let controls: () -> Controls
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(9)) {
            Button(action: open) {
                HostExtensionPreview(entry: entry, dark: dark).frame(maxWidth: .infinity).frame(
                    height: UIScale.pt(52)
                )
                .background(
                    active ? DashSkin.accent(dark).opacity(0.1) : DashSkin.paper(dark),
                    in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
            }.buttonStyle(.edith(.borderless))
            HStack(spacing: UIScale.pt(7)) {
                Button(action: open) {
                    HStack(spacing: UIScale.pt(7)) {
                        Image(systemName: entry.symbolName).font(
                            .system(size: UIScale.pt(13), weight: .semibold)
                        )
                        .foregroundStyle(active ? DashSkin.accent(dark) : DashSkin.inkSoft(dark))
                        Text(entry.title).font(.system(size: UIScale.pt(13), weight: .semibold))
                            .foregroundStyle(DashSkin.ink(dark)).lineLimit(1)
                    }
                }.buttonStyle(.edith(.borderless))
                if !(entry.requiredPermissions + entry.optionalPermissions).isEmpty {
                    HostPermissionInfoButton(
                        permissions: entry.requiredPermissions + entry.optionalPermissions)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .tint(DashSkin.accent(dark)).disabled(toggleDisabled)
                    .accessibilityLabel("\(entry.title) enabled")
            }
            Button(action: open) {
                Text(subtitle).font(.system(size: UIScale.pt(10.5))).foregroundStyle(
                    DashSkin.inkSoft(dark)
                )
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.edith(.borderless))
            controls()
        }.padding(UIScale.pt(11)).frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: UIScale.pt(14)).fill(DashSkin.paper2(dark))
                    Button(action: open) {
                        Color.clear.contentShape(RoundedRectangle(cornerRadius: UIScale.pt(14)))
                    }
                    .buttonStyle(.edith(.borderless))
                }
            }.overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(14)).strokeBorder(
                    DashSkin.line(dark), lineWidth: hovering ? 1.5 : 1)
            }
            .shadow(color: .black.opacity(hovering ? 0.1 : 0), radius: UIScale.pt(8), y: 3)
            .onHover { hovering = $0 }
    }
}
