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
        if ProcessInfo.processInfo.environment["EDITH_CLI"] == "1"
            || (!arguments.isEmpty && !arguments[0].hasPrefix("--extension-")
                && !arguments[0].hasPrefix("--contained-extension-")
                && arguments[0] != "--cli-fixture")
        {
            exit(HostCLI.run(arguments))
        }
        #if EDITH_CLI_FIXTURE
        if arguments.count == 2, arguments[0] == "--cli-fixture",
            Bundle.main.bundleIdentifier?.hasPrefix("com.pulkit.edith.tests.cli-") == true
        {
            do { try HostCLIFixture.run(directory: URL(fileURLWithPath: arguments[1])) } catch {
                exit(1)
            }
            return
        }
        #endif
        do { if try HostContainedRole.run(arguments: arguments) { return } } catch {
            FileHandle.standardError.write(
                Data("The contained extension could not start: \(error).\n".utf8))
            exit(1)
        }
        guard
            HostContract.permitsLaunching(
                identifier: Bundle.main.bundleIdentifier, bundleURL: Bundle.main.bundleURL)

        else {
            FileHandle.standardError.write(
                Data("Install Edith in /Applications before starting the release app.\n".utf8))
            exit(1)
        }
        if arguments.count == 2,
            ["--extension-carrier-worker", "--extension-privileged-fixture"].contains(arguments[0])
        {
            do {
                try HostPrivilegedWorker(
                    bundle: URL(fileURLWithPath: arguments[1]),
                    fixture: arguments[0] == "--extension-privileged-fixture"
                ).run()
            } catch { exit(1) }
            return
        }
        if arguments == ["--extension-carrier"] {
            do { try HostPrivilegedCarrier(approved: true).run() } catch { exit(1) }
            return
        }
        if arguments.count == 2, arguments[0] == "--extension-native-task" {
            do { exit(try HostNativeTask.run(encoded: arguments[1])) } catch {
                FileHandle.standardError.write(
                    Data("The installed extension task could not start.\n".utf8))
                exit(1)
            }
        }
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
        guard arguments.isEmpty else { exit(HostCLI.run(arguments)) }
        HostApplication.main()
    }
}

struct HostApplication: App {
    @State private var updater = HostUpdater()
    @NSApplicationDelegateAdaptor(HostApplicationDelegate.self) private var delegate
    @State private var marketplace: HostMarketplace?
    @State private var cliServer: HostCLIServer?
    @State private var startupError = false
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var theme =
        "accent"
    @AppStorage(AppStorageKeys.General.appearance, store: SharedDefaults.store) private
        var appearance = "system"
    @AppStorage(WindowZoom.defaultsKey, store: SharedDefaults.store) private var zoom = 1.0

    var body: some Scene {
        WindowGroup("Edith", id: "main") {
            GeometryReader { geometry in
                Group {
                    if let marketplace {
                        HostWorkspace(marketplace: marketplace, updater: updater)
                    } else if startupError {
                        ContentUnavailableView(
                            "Edith could not start", systemImage: "exclamationmark.triangle")
                    } else {
                        Text("Opening Edith")
                    }
                }
                .environment(\.compactLayout, geometry.size.width < UIScale.pt(720))
                .tint(themeColor(theme))
                #if EDITH_GUI_FIXTURE
                .background { HostGUIVisibilityProbe() }
                #endif
                .task {
                    guard marketplace == nil, !startupError else { return }
                    do {
                        #if EDITH_GUI_FIXTURE
                        let loaded = try HostGUIFixture.make()
                        let identity = loaded.identity
                        #else
                        let support = try FileManager.default.url(
                            for: .applicationSupportDirectory, in: .userDomainMask,
                            appropriateFor: nil, create: true)
                        let identity = try HostIdentity(
                            identifier: Bundle.main.bundleIdentifier
                                ?? "com.pulkit.edith.dev.extension-host-rebuild",
                            supportDirectory: support)
                        let loaded = try HostMarketplace.live(identity: identity)
                        #endif
                        let gateway = HostCLIGateway(marketplace: loaded)
                        let control = HostCLIServer(identity: identity) { request in
                            try await gateway.execute(request)
                        }
                        try control.start()
                        cliServer = control
                        marketplace = loaded
                        delegate.shutdown = {
                            let ready = await loaded.sessions.shutdown()
                            if ready { control.shutdown() }
                            return ready
                        }
                        await loaded.loadCachedCatalog()
                        await loaded.restoreEnabledExtensions()
                        await loaded.updateInstalledIfDue()
                    } catch { startupError = true }
                }
            }
            .tracksWindowVisibility()
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
        Settings { HostSettingsRedirect() }
    }

    private func synchronizeAppearance() {
        guard let marketplace else { return }
        Task { await marketplace.sessions.synchronizeAppearance(identity: marketplace.identity) }
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
                        if marketplace.sessions.pendingDisableIDs.contains(entry.id) {
                            Text(
                                "Cleanup is still pending. Home and Notch cards are inactive. System resources may remain until cleanup or macOS approval finishes."
                            )
                            .font(.edithText(.caption)).foregroundStyle(.secondary)
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
                    Button("Retry disable") { Task { await marketplace.disable(id: entry.id) } }
                    Button("Enable instead") { Task { await marketplace.enable(id: entry.id) } }
                } else if marketplace.sessions.states[entry.id] == .active {
                    Button("Open") { Task { await marketplace.show(id: entry.id) } }
                    Button("Disable") { Task { await marketplace.disable(id: entry.id) } }
                } else {
                    Button("Enable") { Task { await marketplace.enable(id: entry.id) } }
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
        }
        .buttonStyle(.edith(.secondary))
    }
}
