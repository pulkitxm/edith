import EdithExtensionUI
import EdithHostCore
import Foundation
import SwiftUI

struct HostStoragePage: View {
    let marketplace: HostMarketplace
    let updater: HostUpdater
    var appBundle: URL = Bundle.main.bundleURL
    var appVersion: String? =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    @State private var model = HostStoragePageModel()
    @State private var revision = 0

    init(
        marketplace: HostMarketplace, updater: HostUpdater,
        appBundle: URL = Bundle.main.bundleURL,
        appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String,
        model: HostStoragePageModel = HostStoragePageModel()
    ) {
        self.marketplace = marketplace
        self.updater = updater
        self.appBundle = appBundle
        self.appVersion = appVersion
        _model = State(initialValue: model)
    }

    private var request: [String] {
        [String(revision)]
            + marketplace.installedVersions.flatMap { id, packages in
                packages.map { "\(id):\($0.hostABI):\($0.architecture):\($0.version)" }
            }.sorted()
            + marketplace.sessions.versions.map { "running:\($0.key):\($0.value)" }.sorted()
            + marketplace.sessions.enabledIDs.sorted()
            + marketplace.pendingRemovalIDs.sorted()
            + marketplace.sessions.states.map { "state:\($0.key):\($0.value)" }.sorted()
            + marketplace.available.values.map {
                "catalog:\($0.id):\($0.version):\($0.downloadBytes)"
            }.sorted()
    }

    var body: some View {
        PageScaffold(width: .fluid, pinnedHeader: true) {
            PageHeader("Storage") {
                Button(model.load.isRunning ? "Restart scan" : "Refresh") { revision += 1 }
                    .buttonStyle(.edith(.secondary))
                    .disabled(marketplace.operationID != nil || model.removingID != nil)
            } accessory: {
                Text("Actual files on this Mac, with download sizes shown separately.")
                    .font(.edithText(.callout)).foregroundStyle(.secondary)
            }
        } content: {
            PageLoading(
                state: model.load.state, message: "Refresh to measure storage.", layout: .list,
                retry: { revision += 1 }
            ) {
                if let inventory = model.inventory, let measurement = model.measurement {
                    summary(inventory, measurement)
                    packages(inventory, measurement)
                }
            }
            if model.load.isRunning {
                HStack {
                    LoadingIndicator()
                    Text(
                        model.measurement == nil
                            ? "Scanning known storage roots"
                            : "Refreshing, previous measurements remain visible"
                    )
                    .font(.edithText(.caption))
                    Button("Cancel scan") { model.cancelScan() }.buttonStyle(.edith(.secondary))
                }
            }
            if let message = model.removalError ?? model.load.errorMessage {
                Text(message).font(.edithText(.callout)).foregroundStyle(.orange)
            }
            if let notice = model.removalNotice {
                Text(notice).font(.edithText(.callout)).foregroundStyle(.secondary)
            }
        }
        .pageTask(id: request, active: marketplace.operationID == nil, cancel: model.cancelScan) {
            do {
                let inventory = try HostStorageInventory(
                    marketplace: marketplace, appBundle: appBundle, appVersion: appVersion)
                await model.refresh(inventory: inventory)
            } catch {
                let token = model.load.begin()
                model.load.fail(
                    token,
                    message:
                        "Storage inventory could not be validated. Retry after the current extension operation finishes."
                )
            }
        }
        .onDisappear { model.cancelScan() }
        .navigationTitle("Storage")
    }

    private func summary(_ inventory: HostStorageInventory, _ measurement: HostStorageMeasurement)
        -> some View
    {
        PageCard(title: "Measured storage") {
            HostStorageSizeLine(title: "Total across known roots", bytes: measurement.total)
            HostStorageDistribution(categories: inventory.categories, measurement: measurement)
            ForEach(inventory.categories) { category in
                HostStorageSizeLine(title: category.title, bytes: category.bytes(in: measurement))
            }
            Text(
                "Logical bytes are file contents. Allocated bytes are filesystem blocks, including directories. Hard links count once across categories, assigned to the first path in sorted traversal. APFS clones, compression and shared extents can make exclusive physical disk usage differ."
            )
            .font(.edithText(.caption)).foregroundStyle(.secondary)
            Text(
                "Measured \(measurement.collectedAt.formatted(date: .abbreviated, time: .shortened)). Files may change while scanning. Symbolic link targets and storage outside the known app and extension roots are excluded."
            )
            .font(.edithText(.caption)).foregroundStyle(.secondary)
            ForEach(measurement.issues, id: \.self) {
                Text($0).font(.edithText(.caption)).foregroundStyle(.orange)
            }
            Divider()
            Text(
                "Edith \(inventory.appVersion ?? "version unknown") · Package ABI \(inventory.hostABI) · macOS 14 or later"
            )
            .font(.edithText(.callout))
            Text(
                updater.updateReady.map {
                    "App update ready: \($0). App updates replace the app bundle; extension package updates download separately."
                }
                    ?? "App update availability: \(updater.available ? "check Settings > Updates" : "unknown in this build"). App and extension versions update separately."
            )
            .font(.edithText(.caption)).foregroundStyle(.secondary)
        }
    }

    private func packages(_ inventory: HostStorageInventory, _ measurement: HostStorageMeasurement)
        -> some View
    {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            PageSectionHeader(
                "Optional extensions",
                subtitle:
                    "\(inventory.extensions.count) extensions. Disabling keeps downloads on disk. Removal keeps user data."
            )
            ForEach(inventory.extensions) { entry in
                PageCard(title: entry.title) {
                    HostStorageSizeLine(
                        title: "Installed packages, all versions",
                        bytes: entry.packageBytes(in: measurement))
                    HostStorageSizeLine(
                        title: "Owned extension user data",
                        bytes: measurement.sum(entry.dataScopeIDs))
                    Text(
                        entry.compressedDownloadBytes.map {
                            "Signed catalog compressed download: \(HostStorageSizeLine.format($0)) · version \(entry.catalogVersion ?? "unknown")"
                        }
                            ?? "Signed catalog compressed download: unknown. No compatible verified catalog entry is loaded."
                    )
                    .font(.edithText(.caption)).foregroundStyle(.secondary)
                    if entry.versions.isEmpty {
                        Text("Not downloaded").font(.edithText(.callout)).foregroundStyle(
                            .secondary)
                    }
                    ForEach(entry.versions) { version in
                        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                            Text("\(version.package.version) · \(version.state)").font(
                                .edithText(.callout))
                            Text(
                                "\(version.compatible ? "Compatible with this app" : "Incompatible with this app") · ABI \(version.package.hostABI) · \(version.package.architecture) · macOS \(version.package.minimumSystemVersion)+"
                            )
                            .font(.edithText(.caption)).foregroundStyle(.secondary)
                            HostStorageSizeLine(
                                title: "Version total", bytes: version.bytes(in: measurement))
                            HostStorageSizeLine(
                                title: "Included carrier and worker executables",
                                bytes: measurement.sum(version.executableScopeIDs))
                            HostStorageSizeLine(
                                title: "Included packaged frameworks",
                                bytes: measurement.sum(version.frameworkScopeIDs))
                        }
                    }
                    if !entry.versions.isEmpty || marketplace.pendingRemovalIDs.contains(entry.id) {
                        HStack {
                            if marketplace.pendingRemovalIDs.contains(entry.id) {
                                Text("Pending removal, still on disk until released").font(
                                    .edithText(.caption)
                                ).foregroundStyle(.orange)
                            }
                            Button(
                                model.removingID == entry.id ? "Removing" : "Remove packages",
                                role: .destructive
                            ) {
                                Task {
                                    await model.remove(id: entry.id, marketplace: marketplace)
                                    revision += 1
                                }
                            }
                            .buttonStyle(.edith(.secondary))
                            .disabled(
                                model.removingID != nil || marketplace.operationID != nil
                                    || marketplace.installedVersions[entry.id]?.isEmpty != false
                            )
                            .accessibilityLabel("Remove \(entry.title) packages, keep user data")
                        }
                    }
                }
            }
        }
    }
}

struct HostStorageSizeLine: View {
    let title: String
    let bytes: HostStorageBytes
    @Environment(\.compactLayout) private var compact

    static func format(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func value(_ bytes: HostStorageBytes) -> String {
        let prefix = bytes.complete ? "" : bytes.exists ? "Partial: " : "Unknown: measured "
        return "\(prefix)\(format(bytes.logical)) logical · \(format(bytes.allocated)) allocated"
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer(minLength: UIScale.pt(16))
                Text(Self.value(bytes)).monospacedDigit().foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                Text(title)
                Text(Self.value(bytes)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .font(.edithText(compact ? .caption : .callout))
        .accessibilityElement(children: .combine)
    }
}

struct HostStorageDistribution: View {
    let categories: [HostStorageCategory]
    let measurement: HostStorageMeasurement
    private let colors: [Color] = [.accentColor, .blue, .green, .orange, .purple]

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            Text(
                "Distribution of measured allocated bytes\(measurement.total.complete ? "" : " (partial)")"
            )
            .font(.edithText(.caption)).foregroundStyle(.secondary)
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                        let bytes = category.bytes(in: measurement).allocated
                        if bytes > 0 {
                            Rectangle().fill(colors[index % colors.count])
                                .frame(
                                    width: geometry.size.width * Double(bytes)
                                        / Double(max(1, measurement.total.allocated)))
                        }
                    }
                }
            }
            .frame(height: UIScale.pt(14)).clipShape(RoundedRectangle(cornerRadius: UIScale.pt(4)))
            .accessibilityLabel("Storage distribution. Category sizes are listed below.")
            ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                HStack(spacing: UIScale.pt(6)) {
                    Circle().fill(colors[index % colors.count]).frame(
                        width: UIScale.pt(7), height: UIScale.pt(7))
                    Text(category.title).font(.edithText(.caption)).foregroundStyle(.secondary)
                }
            }
        }
    }
}
