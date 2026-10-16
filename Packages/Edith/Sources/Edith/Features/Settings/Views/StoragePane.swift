import AppKit
import EdithKit
import SwiftUI

struct StoragePane: View {
    private let makeInventory: @MainActor () -> StorageInventory
    @State private var model: StoragePaneModel
    @State private var revision = 0
    @Environment(\.compactLayout) private var compact

    @MainActor init(
        appBundle: URL = Bundle.main.bundleURL,
        inventory: (@MainActor () -> StorageInventory)? = nil,
        model: StoragePaneModel? = nil
    ) {
        makeInventory =
            inventory ?? {
                let version = AppInspectionCenter().info().version
                return StorageInventory(
                    appBundle: appBundle, appVersion: version == "-" ? nil : version)
            }
        _model = State(initialValue: model ?? StoragePaneModel())
    }

    var body: some View {
        PageScaffold(width: .fluid, header: {}) {
            HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(12)) {
                Text("Actual files on this Mac.")
                    .font(.edithText(.callout)).foregroundStyle(.secondary)
                Spacer(minLength: UIScale.pt(8))
                Button(model.load.isRunning ? "Restart scan" : "Refresh") { revision += 1 }
                    .buttonStyle(.edith(.secondary))
            }
            PageLoading(
                state: model.load.state, message: "Refresh to measure storage.", layout: .list,
                retry: { revision += 1 }
            ) {
                if let inventory = model.inventory, let measurement = model.measurement {
                    summary(inventory, measurement)
                    areas(inventory, measurement)
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
            if let message = model.load.errorMessage {
                Text(message).font(.edithText(.callout)).foregroundStyle(.orange)
            }
        }
        .pageTask(id: revision, cancel: model.cancelScan) {
            await model.refresh(inventory: makeInventory())
        }
        .onDisappear { model.cancelScan() }
    }

    private func summary(_ inventory: StorageInventory, _ measurement: StorageMeasurement)
        -> some View
    {
        PageCard(title: "Measured storage") {
            StorageSizeLine(title: "Total across known roots", bytes: measurement.total)
            StorageDistribution(categories: inventory.categories, measurement: measurement)
            ForEach(inventory.categories) { category in
                StorageSizeLine(title: category.title, bytes: category.bytes(in: measurement))
            }
            Text(
                "Logical bytes are file contents. Allocated bytes are filesystem blocks, including directories. Hard links count once across categories, assigned to the first path in sorted traversal. APFS clones, compression and shared extents can make exclusive physical disk usage differ."
            )
            .font(.edithText(.caption)).foregroundStyle(.secondary)
            Text(
                "Measured \(measurement.collectedAt.formatted(date: .abbreviated, time: .shortened)). Files may change while scanning. Symbolic link targets and storage outside the known Edith roots are excluded."
            )
            .font(.edithText(.caption)).foregroundStyle(.secondary)
            ForEach(measurement.issues, id: \.self) {
                Text($0).font(.edithText(.caption)).foregroundStyle(.orange)
            }
            Divider()
            Text("Edith \(inventory.appVersion ?? "version unknown") · macOS 14 or later")
                .font(.edithText(.callout))
        }
    }

    private func areas(_ inventory: StorageInventory, _ measurement: StorageMeasurement)
        -> some View
    {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            PageSectionHeader(
                "By feature",
                subtitle:
                    "\(inventory.areas.count) areas. Sizes are exclusive; nested folders count once."
            )
            LazyVGrid(
                columns: PageMetrics.cardColumns(
                    compact, minimum: 300, spacing: 12, alignment: .top),
                alignment: .leading, spacing: UIScale.pt(12)
            ) {
                ForEach(inventory.areas) { area in
                    let bytes = area.bytes(in: measurement)
                    PageCard(title: area.title) {
                        if bytes.exists || !bytes.complete {
                            StorageSizeLine(title: "Measured", bytes: bytes)
                        }
                        if bytes.exists {
                            Button("Show in Finder") { reveal(area) }
                                .buttonStyle(.edith(.secondary))
                                .accessibilityLabel("Show \(area.title) storage in Finder")
                        } else if bytes.complete {
                            Text("Not created").font(.edithText(.callout))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func reveal(_ area: StorageArea) {
        let existing = area.roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(existing)
    }
}

struct StorageSizeLine: View {
    let title: String
    let bytes: StorageBytes
    @Environment(\.compactLayout) private var compact

    static func format(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func value(_ bytes: StorageBytes) -> String {
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

struct StorageDistribution: View {
    let categories: [StorageCategory]
    let measurement: StorageMeasurement
    private let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .gray]

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
