import AppKit
import EdithHostCore
import EdithExtensionUI
import EdithExtensionSupport
import SwiftUI

@main
struct HostEntry {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--extension-command"] {
            do { try ExtensionCommandSpecification.runWrapper() } catch { exit(1) }
        }
        if arguments == ["--extension-worker"] {
            setenv("EDITH_EXTENSION_WORKER", "1", 1)
            guard setpgid(0, 0) == 0 || getpgrp() == getpid() else { exit(1) }
            do {
                let worker = try HostWorkerApplication()
                worker.run()
            } catch { exit(1) }
            return
        }
        if arguments == ["--version"] {
            print(
                Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                    ?? "development")
            return
        }
        if arguments == ["extensions", "catalog", "--json"] {
            do {
                let data = try JSONEncoder().encode(HostIndex.bundled())
                print(String(decoding: data, as: UTF8.self))
            } catch {
                FileHandle.standardError.write(
                    Data("The extension index could not be read.\n".utf8))
                exit(1)
            }
            return
        }
        HostApplication.main()
    }
}

struct HostApplication: App {
    @State private var updater = HostUpdater()
    @NSApplicationDelegateAdaptor(HostApplicationDelegate.self) private var delegate
    @State private var marketplace: HostMarketplace?
    @State private var startupError = false
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var theme =
        "accent"
    @AppStorage(AppStorageKeys.General.appearance, store: SharedDefaults.store) private
        var appearance = "system"
    @AppStorage(WindowZoom.defaultsKey, store: SharedDefaults.store) private var zoom = 1.0

    var body: some Scene {
        WindowGroup("Edith") {
            GeometryReader { geometry in
                Group {
                    if let marketplace {
                        HostWorkspace(marketplace: marketplace)
                    } else if startupError {
                        ContentUnavailableView(
                            "Edith could not start", systemImage: "exclamationmark.triangle")
                    } else {
                        Text("Opening Edith")
                    }
                }
                .environment(\.compactLayout, geometry.size.width < UIScale.pt(720))
                .tint(themeColor(theme))
                .tracksWindowVisibility()
                .task {
                    guard marketplace == nil, !startupError else { return }
                    do {
                        let support = try FileManager.default.url(
                            for: .applicationSupportDirectory, in: .userDomainMask,
                            appropriateFor: nil, create: true)
                        let identity = try HostIdentity(
                            identifier: Bundle.main.bundleIdentifier
                                ?? "com.pulkit.edith.dev.extension-host-rebuild",
                            supportDirectory: support)
                        let loaded = try HostMarketplace.live(identity: identity)
                        marketplace = loaded
                        delegate.shutdown = { await loaded.sessions.shutdown() }
                        await loaded.loadCachedCatalog()
                        await loaded.restoreEnabledExtensions()
                        await loaded.updateInstalledIfDue()
                    } catch { startupError = true }
                }
            }
            .frame(minWidth: 540, minHeight: 400)
            .onAppear {
                UIScale.apply(zoom); applyAppearance(appearance)
            }
            .onChange(of: zoom) {
                UIScale.apply(zoom); synchronizeAppearance()
            }
            .onChange(of: appearance) {
                applyAppearance(appearance); synchronizeAppearance()
            }
            .onChange(of: theme) { synchronizeAppearance() }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for App Updates") { updater.checkForUpdates() }.disabled(
                    !updater.available)
            }
        }
        Settings { HostSettingsPage() }
    }

    private func synchronizeAppearance() {
        guard let marketplace else { return }
        Task { await marketplace.sessions.synchronizeAppearance(identity: marketplace.identity) }
    }
}

private enum HostWorkspacePage: String, CaseIterable {
    case home = "Home"
    case extensions = "Extensions"
    case customize = "Customize Home and Notch"
}

private struct HostWorkspace: View {
    let marketplace: HostMarketplace
    @State private var page = HostWorkspacePage.home

    var body: some View {
        VStack(spacing: 0) {
            EdithSegmentedPicker(
                "Workspace", selection: $page, options: HostWorkspacePage.allCases,
                label: { $0.rawValue }
            ).padding(UIScale.pt(12))
            Divider()
            switch page {
            case .home:
                HostHomePage(
                    marketplace: marketplace, customize: { page = .customize },
                    extensions: { page = .extensions })
            case .extensions: MarketplacePage(marketplace: marketplace)
            case .customize: HostSurfaceEditor(marketplace: marketplace)
            }
        }
        .onChange(of: marketplace.surfaces.navigation.editorRequest, initial: true) {
            guard let request = marketplace.surfaces.navigation.editorRequest else { return }
            marketplace.surfaces.preferences.set(
                request.target.rawValue, forKey: "surfaceEditorTarget")
            marketplace.surfaces.preferences.set(
                request.tileID ?? "", forKey: "surfaceEditorWidget")
            page = .customize
        }
    }
}

struct MarketplacePage: View {
    @Bindable var marketplace: HostMarketplace
    @State private var search = ""
    @Environment(\.compactLayout) private var compact

    private var filtered: [HostExtension] {
        marketplace.entries.filter {
            search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        PageWorkspace {
            PageHeader("Extensions") {
                Button("Check for Updates") { Task { await marketplace.checkForUpdates() } }
                    .buttonStyle(.edith(.secondary))
                    .disabled(marketplace.operationID != nil)
            } accessory: {
                VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                    Text("Download the features you need.").font(.edithText(.body)).foregroundStyle(
                        .secondary)
                    TextField("Find extensions", text: $search).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Find extensions")
                    if let error = marketplace.error {
                        Text(error).foregroundStyle(.red).font(.edithText(.callout))
                    }
                    if marketplace.offline {
                        Text("You are offline. Installed extensions are still available.")
                            .foregroundStyle(.secondary).font(.edithText(.callout))
                    }
                }
            }
        } content: {
            VStack(spacing: 0) {
                List(filtered) { entry in
                    VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                        HStack(spacing: UIScale.pt(14)) {
                            Image(systemName: entry.symbolName).font(.edithText(.title2)).frame(
                                width: UIScale.pt(32))
                            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                                Text(entry.title).font(.edithText(.headline))
                                Text(subtitle(entry)).font(.edithText(.caption)).foregroundStyle(
                                    .secondary)
                            }
                            Spacer()
                            if !compact { controls(entry) }
                        }
                        if compact {
                            HStack {
                                Spacer(); controls(entry)
                            }
                        }
                    }
                    .padding(.vertical, UIScale.pt(10))
                    .disabled(marketplace.operationID != nil)
                }
                Toggle(
                    "Automatically update installed extensions",
                    isOn: $marketplace.automaticallyUpdatesExtensions
                )
                .font(.edithText(.callout)).padding(UIScale.pt(16))
            }
        }
    }

    private func subtitle(_ entry: HostExtension) -> String {
        if let package = marketplace.installed[entry.id] {
            return
                "\(marketplace.sessions.states[entry.id] == .active ? "Enabled" : "Disabled") · \(package.version)"
        }
        return marketplace.downloadedIDs.contains(entry.id)
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
                if marketplace.sessions.states[entry.id] == .active {
                    Button("Open") { Task { await marketplace.show(id: entry.id) } }
                    Button("Disable") { Task { await marketplace.disable(id: entry.id) } }
                } else {
                    Button("Enable") { Task { await marketplace.enable(id: entry.id) } }
                }
                Button("Remove") { Task { await marketplace.remove(id: entry.id) } }
            } else {
                Button(marketplace.downloadedIDs.contains(entry.id) ? "Update" : "Download") {
                    Task { await marketplace.download(id: entry.id) }
                }
            }
        }
        .buttonStyle(.edith(.secondary))
    }
}
