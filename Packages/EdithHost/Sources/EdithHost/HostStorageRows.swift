import AppKit
import EdithExtensionUI
import EdithHostCore
import ExtensionMarketplace
import Foundation
import SwiftUI

enum HostStorageReveal {
    static func show(_ urls: [URL]) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(existing)
    }

    static func display(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

enum HostStorageFormat {
    static func size(_ bytes: HostStorageBytes) -> String {
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

struct HostStorageRow<Details: View>: View {
    let usage: HostStorageUsage
    let total: Int64
    let color: Color
    let expanded: Bool
    let contents: [HostStorageEntry]?
    let toggle: () -> Void
    @ViewBuilder let details: () -> Details
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
                        HostStorageItemIcon(item: usage.item, color: color)
                        Text(usage.item.title).font(.edithText(.callout)).lineLimit(1)
                        Spacer(minLength: UIScale.pt(8))
                        Text(HostStorageFormat.share(usage.bytes.allocated, of: total))
                            .font(.edithText(.caption)).foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(HostStorageFormat.size(usage.bytes))
                            .font(.edithText(.callout).weight(.medium)).monospacedDigit()
                            .frame(minWidth: UIScale.pt(76), alignment: .trailing)
                    }
                }
                .buttonStyle(.edith(.row))
                .accessibilityElement(children: .combine)
                .accessibilityHint(expanded ? "Hides details" : "Shows what is inside")
                .accessibilityAddTraits(.isButton)
                Button {
                    HostStorageReveal.show(usage.item.roots)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.edith(.iconOnly))
                .help("Show in Finder")
                .accessibilityLabel("Show \(usage.item.title) in Finder")
            }
            .padding(.vertical, UIScale.pt(2))
            if expanded {
                VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                    details()
                    HostStorageRowDetails(usage: usage, contents: contents)
                }
                .padding(.leading, UIScale.pt(54))
                .padding(.bottom, UIScale.pt(10))
                .transition(.opacity)
            }
        }
    }
}

struct HostStorageItemIcon: View {
    let item: HostStorageItem
    let color: Color

    var body: some View {
        Group {
            if item.id == "app", let bundle = item.roots.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: bundle.path))
                    .resizable().interpolation(.high)
            } else {
                Image(systemName: item.symbolName)
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

struct HostStoragePackageDetails: View {
    let entry: HostStorageExtension
    let measurement: HostStorageMeasurement
    let pendingRemoval: Bool
    let removing: Bool
    let canRemove: Bool
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            Text("Packages and data")
                .font(.edithText(.caption).weight(.semibold)).foregroundStyle(.secondary)
            line("Installed packages, all versions", entry.packageBytes(in: measurement))
            line("Extension user data", measurement.sum(entry.dataScopeIDs))
            if !entry.sharedDataScopeIDs.isEmpty {
                line(
                    "Shared user data, counted once in the total",
                    measurement.sum(entry.sharedDataScopeIDs))
            }
            Text(
                entry.compressedDownloadBytes.map {
                    "Compressed download: \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) · version \(entry.catalogVersion ?? "unknown")"
                } ?? "Compressed download: unknown, no compatible verified catalog entry."
            )
            .font(.edithText(.caption)).foregroundStyle(.secondary)
            ForEach(entry.versions) { version in
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    line(
                        "\(version.package.version) · \(version.state)",
                        version.bytes(in: measurement))
                    Text(
                        "\(version.compatible ? "Compatible with this app" : "Incompatible with this app") · ABI \(version.package.hostABI) · \(version.package.architecture) · macOS \(version.package.minimumSystemVersion.description)+"
                    )
                    .font(.edithText(.caption)).foregroundStyle(.secondary)
                }
            }
            if !entry.versions.isEmpty || pendingRemoval {
                Text(
                    "Removing deletes every package version above. User data, shared files and selected music folders are kept."
                )
                .font(.edithText(.caption)).foregroundStyle(.secondary)
                HStack {
                    if pendingRemoval {
                        Text("Pending removal, still on disk until released")
                            .font(.edithText(.caption)).foregroundStyle(.orange)
                    }
                    Button(removing ? "Removing" : "Remove packages", role: .destructive) {
                        remove()
                    }
                    .buttonStyle(.edith(.secondary))
                    .disabled(removing || !canRemove)
                    .accessibilityLabel("Remove \(entry.title) packages, keep user data")
                }
            }
        }
    }

    private func line(_ title: String, _ bytes: HostStorageBytes) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(8)) {
            Text(title).font(.edithText(.callout))
            Spacer(minLength: UIScale.pt(8))
            Text(HostStorageFormat.size(bytes))
                .font(.edithText(.callout)).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct HostStorageRowDetails: View {
    let usage: HostStorageUsage
    let contents: [HostStorageEntry]?

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
                                HostStorageFormat.share(
                                    entry.bytes.allocated, of: usage.bytes.allocated)
                            )
                            .font(.edithText(.caption)).foregroundStyle(.secondary)
                            .monospacedDigit()
                            Text(HostStorageFormat.size(entry.bytes))
                                .font(.edithText(.callout)).monospacedDigit()
                                .frame(minWidth: UIScale.pt(76), alignment: .trailing)
                            Button {
                                HostStorageReveal.show([entry.url])
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
                    Text(HostStorageReveal.display(root))
                        .font(.edithText(.caption, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, UIScale.pt(4))
        }
    }
}

struct HostStorageBar: View {
    static let palette: [Color] = [.blue, .green, .orange, .purple, .pink]
    static let otherColor = Color.gray

    static func color(at index: Int) -> Color {
        index < palette.count ? palette[index] : otherColor
    }

    let usage: [HostStorageUsage]
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
