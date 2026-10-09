import AppKit
import EdithHostCore
import SwiftUI

@main
struct HostEntry {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--extension-worker"] {
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
    @NSApplicationDelegateAdaptor(HostApplicationDelegate.self) private var delegate
    @State private var marketplace: HostMarketplace?
    @State private var startupError = false

    var body: some Scene {
        WindowGroup("Edith") {
            Group {
                if let marketplace {
                    MarketplacePage(marketplace: marketplace)
                } else if startupError {
                    ContentUnavailableView(
                        "Edith could not start", systemImage: "exclamationmark.triangle")
                } else {
                    Text("Opening Edith")
                }
            }
            .frame(minWidth: 540, minHeight: 400)
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
                } catch { startupError = true }
            }
        }
    }
}

struct MarketplacePage: View {
    @Bindable var marketplace: HostMarketplace
    @State private var search = ""

    private var filtered: [HostExtension] {
        marketplace.entries.filter {
            search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extensions").font(.largeTitle.bold())
                    Text("Download the features you need.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Check for Updates") { Task { await marketplace.checkForUpdates() } }
                    .disabled(marketplace.operationID != nil)
            }
            .padding(24)
            if let error = marketplace.error {
                Text(error).foregroundStyle(.red).padding(.horizontal, 24).padding(.bottom, 12)
            }
            if marketplace.offline {
                Text("You are offline. Installed extensions are still available.")
                    .foregroundStyle(.secondary).padding(.bottom, 12)
            }
            List(filtered) { entry in
                HStack(spacing: 14) {
                    Image(systemName: entry.symbolName).font(.title2).frame(width: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title).font(.headline)
                        if let package = marketplace.installed[entry.id] {
                            Text(
                                "\(marketplace.sessions.states[entry.id] == .active ? "Enabled" : "Disabled") · \(package.version)"
                            ).foregroundStyle(.secondary)
                        } else {
                            Text("Not installed").foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if marketplace.operationID == entry.id {
                        ProgressView(value: marketplace.progress).frame(width: 90)
                            .accessibilityLabel("Downloading \(entry.title)")
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
                        Button("Download") { Task { await marketplace.download(id: entry.id) } }
                            .disabled(marketplace.operationID != nil)
                    }
                }
                .disabled(marketplace.operationID != nil)
                .padding(.vertical, 10)
            }
            .searchable(text: $search, prompt: "Find extensions")
        }
    }
}
