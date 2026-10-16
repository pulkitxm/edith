import AppKit
import EdithKit
import SwiftUI

struct StoragePane: View {
    private let makeInventory: @MainActor () -> StorageInventory
    @State private var model: StoragePaneModel
    @State private var revision = 0
    @State private var showsSmallItems = false

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
            PageLoading(
                state: model.load.state, message: "Refresh to measure storage.", layout: .list,
                retry: { revision += 1 }
            ) {
                if let inventory = model.inventory, let measurement = model.measurement {
                    let usage = inventory.usage(in: measurement)
                    summary(measurement, usage)
                    breakdown(measurement, usage)
                    Text(
                        "Edith \(inventory.appVersion ?? "version unknown") · Measured \(measurement.collectedAt.formatted(date: .omitted, time: .shortened))"
                    )
                    .font(.edithText(.caption)).foregroundStyle(.secondary)
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

    private func summary(_ measurement: StorageMeasurement, _ usage: [StorageUsage])
        -> some View
    {
        PageCard {
            HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(12)) {
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text("Edith is using")
                        .font(.edithText(.callout)).foregroundStyle(.secondary)
                    Text(StorageFormat.size(measurement.total))
                        .font(.edithText(.largeTitle).weight(.semibold)).monospacedDigit()
                }
                Spacer(minLength: UIScale.pt(8))
                if model.load.isRunning {
                    LoadingIndicator()
                    Button("Cancel") { model.cancelScan() }.buttonStyle(.edith(.secondary))
                } else {
                    Button("Refresh") { revision += 1 }.buttonStyle(.edith(.secondary))
                }
            }
            StorageBar(usage: usage, total: measurement.total.allocated)
            if let largest = usage.first, measurement.total.allocated > 0 {
                Text(
                    "Largest: \(largest.item.title), \(StorageFormat.share(largest.bytes.allocated, of: measurement.total.allocated))"
                )
                .font(.edithText(.callout)).foregroundStyle(.secondary)
            }
            if !measurement.total.complete {
                Text("Some files could not be read, so the real total may be higher.")
                    .font(.edithText(.caption)).foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func breakdown(_ measurement: StorageMeasurement, _ usage: [StorageUsage])
        -> some View
    {
        let total = measurement.total.allocated
        let top = usage.prefix(StorageFormat.visibleRows)
        let rest = usage.dropFirst(StorageFormat.visibleRows)
        return PageCard(title: "What is using space") {
            VStack(spacing: 0) {
                ForEach(Array(top.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider() }
                    row(entry, total: total, color: StorageBar.color(at: index))
                }
                if !rest.isEmpty {
                    Divider()
                    Button(
                        showsSmallItems
                            ? "Hide smaller items"
                            : "Show \(rest.count) smaller items · \(StorageFormat.size(rest.reduce(into: StorageBytes()) { $0.include($1.bytes) }))"
                    ) { showsSmallItems.toggle() }
                    .buttonStyle(.edith(.borderless))
                    .padding(.vertical, UIScale.pt(6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if showsSmallItems {
                        ForEach(Array(rest)) { entry in
                            Divider()
                            row(entry, total: total, color: StorageBar.otherColor)
                        }
                    }
                }
            }
        }
    }

    private func row(_ usage: StorageUsage, total: Int64, color: Color) -> some View {
        StorageRow(
            usage: usage, total: total, color: color,
            expanded: model.expanded.contains(usage.id),
            contents: model.contents[usage.id],
            toggle: { model.toggle(usage.item) })
    }
}

enum StorageReveal {
    static func show(_ urls: [URL]) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(existing)
    }

    static func display(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

enum StorageFormat {
    static func size(_ bytes: StorageBytes) -> String {
        let value = ByteCountFormatter.string(fromByteCount: bytes.allocated, countStyle: .file)
        return bytes.complete ? value : "At least \(value)"
    }

    static func share(_ part: Int64, of total: Int64) -> String {
        let fraction = Double(part) / Double(max(1, total))
        return fraction < 0.01
            ? "under 1%" : fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    static let visibleRows = 6
}

struct StorageRow: View {
    let usage: StorageUsage
    let total: Int64
    let color: Color
    let expanded: Bool
    let contents: [StorageEntry]?
    let toggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: UIScale.pt(10)) {
                Button {
                    withAnimation(Motion.animation(Motion.snap, reduceMotion: reduceMotion)) {
                        toggle()
                    }
                } label: {
                    HStack(spacing: UIScale.pt(10)) {
                        Image(systemName: "chevron.right")
                            .font(.edithText(.caption).weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: UIScale.pt(10))
                        StorageItemIcon(item: usage.item, color: color)
                        Text(usage.item.title).font(.edithText(.callout)).lineLimit(1)
                        Spacer(minLength: UIScale.pt(8))
                        Text(StorageFormat.share(usage.bytes.allocated, of: total))
                            .font(.edithText(.caption)).foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(StorageFormat.size(usage.bytes))
                            .font(.edithText(.callout).weight(.medium)).monospacedDigit()
                            .frame(minWidth: UIScale.pt(76), alignment: .trailing)
                    }
                }
                .buttonStyle(.edith(.row))
                .accessibilityElement(children: .combine)
                .accessibilityHint(expanded ? "Hides details" : "Shows what is inside")
                .accessibilityAddTraits(.isButton)
                Button {
                    StorageReveal.show(usage.item.roots)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.edith(.iconOnly))
                .help("Show in Finder")
                .accessibilityLabel("Show \(usage.item.title) in Finder")
            }
            .padding(.vertical, UIScale.pt(2))
            if expanded {
                StorageRowDetails(usage: usage, contents: contents)
                    .padding(.leading, UIScale.pt(54))
                    .padding(.bottom, UIScale.pt(10))
                    .transition(.opacity)
            }
        }
    }
}

struct StorageItemIcon: View {
    static let symbols: [String: String] = [
        "machines": "server.rack",
        "database": "cylinder.fill",
        "clipboard": "doc.on.clipboard",
        "usage": "chart.bar.fill",
        "attention": "hourglass",
        "music": "music.note",
        "studio": "wand.and.stars",
        "videoProjects": "film",
        "virtualCamera": "web.camera",
        "seoAudit": "doc.text.magnifyingglass",
        "codeStats": "chart.line.uptrend.xyaxis",
        "latex": "doc.richtext",
        "plugins": "square.stack.3d.up",
        "shelf": "tray.full",
        "tools": "terminal",
        "snapshots": "clock.arrow.circlepath",
        "notchBrowser": "globe",
        "selected-music-directory": "music.note.list",
        "store": "cylinder.split.1x2",
        "cache": "archivebox",
        "logs-preferences": "gearshape",
        "other": "folder",
    ]

    let item: StorageItem
    let color: Color

    var body: some View {
        Group {
            if item.id == "app", let bundle = item.roots.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: bundle.path))
                    .resizable().interpolation(.high)
            } else {
                Image(systemName: Self.symbols[item.id] ?? "folder")
                    .font(.edithText(.callout).weight(.medium))
                    .foregroundStyle(color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        color.opacity(0.16), in: RoundedRectangle(cornerRadius: UIScale.pt(6)))
            }
        }
        .frame(width: UIScale.pt(26), height: UIScale.pt(26))
        .accessibilityHidden(true)
    }
}

struct StorageRowDetails: View {
    let usage: StorageUsage
    let contents: [StorageEntry]?

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            if let contents {
                if contents.isEmpty {
                    Text("Nothing inside to list.")
                        .font(.edithText(.caption)).foregroundStyle(.secondary)
                } else {
                    Text("Largest inside")
                        .font(.edithText(.caption).weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(contents) { entry in
                        HStack(spacing: UIScale.pt(8)) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                                .resizable().interpolation(.high)
                                .frame(width: UIScale.pt(18), height: UIScale.pt(18))
                                .accessibilityHidden(true)
                            Text(entry.url.lastPathComponent)
                                .font(.edithText(.callout)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: UIScale.pt(8))
                            Text(
                                StorageFormat.share(
                                    entry.bytes.allocated, of: usage.bytes.allocated)
                            )
                            .font(.edithText(.caption)).foregroundStyle(.secondary)
                            .monospacedDigit()
                            Text(StorageFormat.size(entry.bytes))
                                .font(.edithText(.callout)).monospacedDigit()
                                .frame(minWidth: UIScale.pt(76), alignment: .trailing)
                            Button {
                                StorageReveal.show([entry.url])
                            } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .buttonStyle(.edith(.iconOnly))
                            .help("Show in Finder")
                            .accessibilityLabel("Show \(entry.url.lastPathComponent) in Finder")
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } else {
                HStack(spacing: UIScale.pt(8)) {
                    LoadingIndicator()
                    Text("Looking inside")
                        .font(.edithText(.caption)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text("Stored in")
                    .font(.edithText(.caption).weight(.semibold)).foregroundStyle(.secondary)
                ForEach(
                    usage.item.roots.filter { FileManager.default.fileExists(atPath: $0.path) },
                    id: \.path
                ) { root in
                    Text(StorageReveal.display(root))
                        .font(.edithText(.caption, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, UIScale.pt(4))
        }
    }
}

struct StorageBar: View {
    static let palette: [Color] = [.blue, .green, .orange, .purple, .pink]
    static let otherColor = Color.gray

    static func color(at index: Int) -> Color {
        index < palette.count ? palette[index] : otherColor
    }

    let usage: [StorageUsage]
    let total: Int64

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(segments, id: \.id) { segment in
                    Rectangle().fill(segment.color)
                        .frame(
                            width: geometry.size.width * Double(segment.bytes)
                                / Double(max(1, total)))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: UIScale.pt(12))
        .background(Color.secondary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(4)))
        .accessibilityHidden(true)
    }

    private var segments: [(id: String, bytes: Int64, color: Color)] {
        let leading = usage.prefix(Self.palette.count).enumerated()
            .map {
                (
                    id: $0.element.id, bytes: $0.element.bytes.allocated,
                    color: Self.color(at: $0.offset)
                )
            }
        let rest = total - leading.reduce(0) { $0 + $1.bytes }
        return rest > 0 ? leading + [(id: "rest", bytes: rest, color: Self.otherColor)] : leading
    }
}
