import AppKit
import EdithKit
import SwiftUI

struct BlitzTreePage: View {
    @State private var model = BlitzTreeModel()
    @State private var list = BlitzTreeList.children
    @State private var showingSetup = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(18)) {
                PageHeader {
                    Text("BlitzTree")
                } accessory: {
                    HStack {
                        if model.scanning {
                            ProgressView().controlSize(.small)
                            Button("Cancel", action: model.cancel)
                        } else if let root = model.root {
                            Button("Rescan", systemImage: "arrow.clockwise") {
                                model.scan(root, remember: false)
                            }
                        }
                        Button("Choose folder", systemImage: "folder") { chooseFolder() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                    navigation
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                    if let report = model.report {
                        results(report)
                    } else {
                        emptyState
                    }
                }
                .pageGutter(compact)
            }
            .padding(.bottom, UIScale.pt(PageMetrics.bottom))
        }
        .background(DashSkin.paper(scheme == .dark))
        .onDisappear { model.cancel() }
        .sheet(isPresented: $showingSetup) {
            ToolProvisioningPanel(
                title: "Set up BlitzTree", tools: [.blitzTree],
                continueAction: {
                    showingSetup = false
                }
            )
            .frame(width: UIScale.pt(520))
        }
    }

    private var navigation: some View {
        HStack {
            Button("Back", systemImage: "chevron.left", action: model.back)
                .disabled(model.history.isEmpty)
            Text(model.root ?? "Choose a folder to explore its disk usage")
                .font(.system(size: UIScale.pt(12), design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button("Set up CLI") { showingSetup = true }
        }
    }

    private var emptyState: some View {
        VStack(spacing: UIScale.pt(12)) {
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: UIScale.pt(40)))
                .foregroundStyle(.secondary)
            Text(model.scanning ? "Scanning folder..." : "See where your space goes")
                .font(DashSkin.heading(24))
            Text(
                model.scanning
                    ? "BlitzTree is reading filesystem metadata. You can cancel at any time."
                    : "Explore a disk-space treemap, large files and cleanup candidates."
            )
            .foregroundStyle(.secondary)
            Link(
                "About BlitzTree",
                destination: URL(string: "https://github.com/ahmedkhaleel2004/blitztree")!)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, UIScale.pt(64))
    }

    @ViewBuilder private func results(_ report: BlitzTreeReport) -> some View {
        HStack(spacing: UIScale.pt(24)) {
            metric("Allocated", bytes(report.summary.allocatedBytes))
            metric("Files", report.summary.fileCount.formatted())
            metric("Folders", report.summary.directoryCount.formatted())
            metric("Scan", String(format: "%.2f s", report.scanSeconds))
        }
        if !report.coverage.complete {
            Label(
                "Partial scan: \(report.coverage.errors) errors, \(report.coverage.skippedCloudDirectories) cloud folders and \(report.coverage.skippedMountPoints) mount points skipped.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout)
            .foregroundStyle(.orange)
        }
        BlitzTreeMap(report: report) { entry in activate(entry) }
            .frame(height: UIScale.pt(280))
        Text("Allocated space, not guaranteed recoverable space. Click a folder to scan inside it.")
            .font(.caption)
            .foregroundStyle(.secondary)
        Picker("Show", selection: $list) {
            ForEach(BlitzTreeList.allCases) { item in Text(item.rawValue).tag(item) }
        }
        .pickerStyle(.segmented)
        if list == .candidates {
            Text(
                "\(report.report.candidateCount) candidates. Review each folder in Finder before removing anything.\(report.report.truncated ? " Showing the largest 200." : "")"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        let entries = list.entries(report)
        if entries.isEmpty {
            Text(
                list == .candidates
                    ? "No cleanup candidates meet the 50 MB threshold." : "No entries to show."
            )
            .foregroundStyle(.secondary)
            .padding(.vertical, UIScale.pt(24))
        }
        LazyVStack(spacing: 0) {
            ForEach(entries) { entry in
                HStack(spacing: UIScale.pt(12)) {
                    Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                        .foregroundStyle(entry.isDirectory ? Color.blue : Color.teal)
                    Button {
                        activate(entry)
                    } label: {
                        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                            Text(entry.name).fontWeight(.medium)
                            Text(entry.reason ?? entry.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if !entry.complete {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .help("This entry was only partially scanned")
                    }
                    Text(bytes(entry.allocatedBytes)).monospacedDigit()
                    Button("Reveal", systemImage: "arrow.up.forward.square") { reveal(entry) }
                        .labelStyle(.iconOnly)
                        .help("Reveal in Finder")
                }
                .padding(.vertical, UIScale.pt(10))
                Divider()
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2).monospacedDigit()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.scan(url.path)
        }
    }

    private func activate(_ entry: BlitzTreeReport.Entry) {
        if entry.isDirectory { model.scan(entry.path) } else { reveal(entry) }
    }

    private func reveal(_ entry: BlitzTreeReport.Entry) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}

private enum BlitzTreeList: String, CaseIterable, Identifiable {
    case children = "Contents"
    case directories = "Largest folders"
    case files = "Largest files"
    case candidates = "Cleanup candidates"

    var id: String { rawValue }

    func entries(_ report: BlitzTreeReport) -> [BlitzTreeReport.Entry] {
        switch self {
        case .children: report.report.inventory.largestChildren
        case .directories: report.report.inventory.largestDirectories
        case .files: report.report.inventory.largestFiles
        case .candidates: report.report.candidates
        }
    }
}
