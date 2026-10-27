import EdithExtensionUI
import EdithHostCore
import Foundation
import SwiftUI

struct HostStoragePage: View {
    let marketplace: HostMarketplace
    var appBundle: URL = Bundle.main.bundleURL
    var appVersion: String? =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    @State private var model = HostStoragePageModel()
    @State private var revision = 0
    @State private var showsSmallItems = false

    init(
        marketplace: HostMarketplace,
        appBundle: URL = Bundle.main.bundleURL,
        appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String,
        model: HostStoragePageModel = HostStoragePageModel()
    ) {
        self.marketplace = marketplace
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

    private var busy: Bool { model.removingID != nil }

    var body: some View {
        PageScaffold(width: .fluid, header: {}) {
            PageLoading(
                state: model.load.state, message: "Refresh to measure storage.", layout: .list,
                retry: { revision += 1 }
            ) {
                if let inventory = model.inventory, let measurement = model.measurement {
                    let usage = inventory.usage(in: measurement)
                    summary(measurement, usage)
                    breakdown(inventory, measurement, usage)
                    Text(
                        "Edith \(inventory.appVersion ?? "version unknown") · Measured \(measurement.collectedAt.formatted(date: .omitted, time: .shortened))"
                    )
                    .font(.edithText(.caption)).foregroundStyle(.secondary)
                }
            }
            if let message = model.removalError ?? model.load.errorMessage {
                Text(message).font(.edithText(.callout)).foregroundStyle(.orange)
            }
            if let notice = model.removalNotice {
                Text(notice).font(.edithText(.callout)).foregroundStyle(.secondary)
            }
        }
        .pageTask(id: request, active: !marketplace.busy, cancel: model.cancelScan) {
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

    private func summary(_ measurement: HostStorageMeasurement, _ usage: [HostStorageUsage])
        -> some View
    {
        PageCard {
            HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(12)) {
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text("Edith is using")
                        .font(.edithText(.callout)).foregroundStyle(.secondary)
                    Text(HostStorageFormat.size(measurement.total))
                        .font(.edithText(.largeTitle).weight(.semibold)).monospacedDigit()
                }
                Spacer(minLength: UIScale.pt(8))
                if model.load.isRunning {
                    LoadingIndicator()
                    Button("Cancel") { model.cancelScan() }.buttonStyle(.edith(.secondary))
                } else {
                    Button("Refresh") { revision += 1 }
                        .buttonStyle(.edith(.secondary)).disabled(busy)
                }
            }
            HostStorageBar(usage: usage, total: measurement.total.allocated)
            if let largest = usage.first, measurement.total.allocated > 0 {
                Text(
                    "Largest: \(largest.item.title), \(HostStorageFormat.share(largest.bytes.allocated, of: measurement.total.allocated))"
                )
                .font(.edithText(.callout)).foregroundStyle(.secondary)
            }
            if !measurement.total.complete {
                Text("Some files could not be read, so the real total may be higher.")
                    .font(.edithText(.caption)).foregroundStyle(.orange)
            }
            ForEach(measurement.issues, id: \.self) {
                Text($0).font(.edithText(.caption)).foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func breakdown(
        _ inventory: HostStorageInventory, _ measurement: HostStorageMeasurement,
        _ usage: [HostStorageUsage]
    ) -> some View {
        let total = measurement.total.allocated
        let top = usage.prefix(HostStorageFormat.visibleRows)
        let rest = usage.dropFirst(HostStorageFormat.visibleRows)
        return PageCard(title: "What is using space") {
            VStack(spacing: 0) {
                ForEach(Array(top.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider() }
                    row(
                        entry, inventory, measurement, total: total,
                        color: HostStorageBar.color(at: index))
                }
                if !rest.isEmpty {
                    Divider()
                    Button(
                        showsSmallItems
                            ? "Hide smaller items"
                            : "Show \(rest.count) smaller items · \(HostStorageFormat.size(rest.reduce(into: HostStorageBytes()) { $0.include($1.bytes) }))"
                    ) { showsSmallItems.toggle() }
                    .buttonStyle(.edith(.borderless))
                    .padding(.vertical, UIScale.pt(6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if showsSmallItems {
                        ForEach(Array(rest)) { entry in
                            Divider()
                            row(
                                entry, inventory, measurement, total: total,
                                color: HostStorageBar.otherColor)
                        }
                    }
                }
            }
        }
    }

    private func row(
        _ usage: HostStorageUsage, _ inventory: HostStorageInventory,
        _ measurement: HostStorageMeasurement, total: Int64, color: Color
    ) -> some View {
        let entry = inventory.extensions.first { $0.id == usage.item.extensionID }
        return HostStorageRow(
            usage: usage, total: total, color: color,
            expanded: model.expanded.contains(usage.id),
            contents: model.contents[usage.id],
            toggle: { model.toggle(usage.item) }
        ) {
            if let entry {
                HostStoragePackageDetails(
                    entry: entry, measurement: measurement,
                    pendingRemoval: marketplace.pendingRemovalIDs.contains(entry.id),
                    removing: model.removingID == entry.id,
                    canRemove: !busy && !marketplace.isBusy(entry.id)
                        && marketplace.installedVersions[entry.id]?.isEmpty == false
                ) {
                    Task {
                        await model.remove(id: entry.id, marketplace: marketplace)
                        revision += 1
                    }
                }
            }
        }
    }
}
