import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct BlitzTreePage: View {
    static let title = "Disk Map"
    static let subtitle =
        "See which files and folders take the most space. Scanning never changes anything."
    @State var model: BlitzTreeModel
    @State private var pendingRemoval: BlitzTreeReport.Entry?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.windowRouter) private var router

    var body: some View {
        PageScaffold(pinnedHeader: true) {
            VStack(spacing: 0) {
                PageHeader(
                    subtitle: Self.subtitle,
                    title: { Text(Self.title) },
                    trailing: { headerActions })
                Divider()
            }
        } content: {
            switch presentation {
            case .intro: introState
            case .scanning: scanningState
            case .failed: failedState
            case .cancelled: cancelledState
            case .results:
                PageLoading(
                    state: model.loading.state,
                    message: model.loading.errorMessage ?? "The folder scan was interrupted.",
                    layout: .analytics, refreshing: model.loading.isRefreshing,
                    retry: { if let root = model.root { model.scan(root, remember: false) } },
                    cancel: model.cancel
                ) {
                    if let report = model.report { results(report) }
                }
            }
        }
        .navigationRoute("list", selection: $model.list)
        .navigationRoute("folder", selection: folderBinding, isValid: folderIsValid)
        .confirmationDialog(
            "Move \(pendingRemoval?.name ?? "this item") to the Trash?",
            isPresented: Binding(
                get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
            ), titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let entry = pendingRemoval { model.trash(entry) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            if let entry = pendingRemoval {
                Text(
                    "\(entry.path)\nAbout \(bytes(entry.allocatedBytes)) of disk space. It stays in the Trash until you empty it, so you can put it back."
                )
            }
        }
        .pageRefresh(interval: { model.refreshInterval }) { await model.refreshRemote() }
    }

    private var presentation: BlitzTreePresentation {
        BlitzTreePresentation(
            hasRoot: model.root != nil, hasReport: model.report != nil,
            scanning: model.scanning, hasError: model.error != nil)
    }

    private var dark: Bool { scheme == .dark }

    @ViewBuilder private var headerActions: some View {
        switch presentation {
        case .scanning:
            Button(action: model.cancel) {
                Text("Cancel scan").font(.edithText(.body))
            }
            .buttonStyle(.edith(.secondary))
            .help("Stop measuring. Nothing has been changed.")
        case .results:
            HStack(spacing: UIScale.pt(8)) {
                if let root = model.root {
                    Button {
                        model.scan(root, remember: false)
                    } label: {
                        Label("Rescan", edith: .refresh).font(.edithText(.body))
                    }
                    .buttonStyle(.edith(.secondary))
                    .disabled(model.removing || model.scanning)
                    .help(
                        model.removing
                            ? "Wait for the item to finish moving to the Trash."
                            : "Measure this folder again.")
                }
                Button {
                    chooseFolder()
                } label: {
                    Label("Choose folder…", edith: .folder).font(.edithText(.body))
                }
                .buttonStyle(.edith(.secondary))
                .disabled(model.removing)
                .help(
                    model.removing
                        ? "Wait for the item to finish moving to the Trash."
                        : "Pick a different folder to measure.")
            }
        case .intro, .failed, .cancelled:
            EmptyView()
        }
    }

    private var emptyHeight: CGFloat { UIScale.pt(compact ? 460 : 540) }

    private var introState: some View {
        PageEmptyState(
            icon: .blitztree,
            title: "See where your space goes",
            message:
                "Disk Map measures a folder and draws it as blocks sized by how much space each file or folder uses.",
            steps: [
                PageGuideStep(
                    icon: .folder, title: "1. Pick a folder",
                    detail: "Start with your home folder or any drive. Nothing is changed."),
                PageGuideStep(
                    icon: .blitztree, title: "2. Explore",
                    detail:
                        "Click a block to open that folder. The largest items are listed below it."
                ),
                PageGuideStep(
                    icon: .trash, title: "3. Free up space",
                    detail:
                        "Reveal items in Finder, or move them to the Trash where you can put them back."
                ),
            ],
            primary: PageAction(
                "Scan my home folder", icon: .home, identifier: "blitztree.scan-home"
            ) {
                model.scan(NSHomeDirectory())
            },
            secondary: PageAction("Choose a folder…", identifier: "blitztree.choose") {
                chooseFolder()
            },
            footnote: "Large folders can take a minute. Files that only live in iCloud are skipped."
        )
        .frame(minHeight: emptyHeight)
        .pageFillViewport()
    }

    private var scanningState: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
            if let root = model.root { location(root) }
            VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
                HStack(alignment: .center, spacing: UIScale.pt(12)) {
                    PageGuideBadge(icon: .blitztree, size: 40)
                    VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                        Text("Measuring \(folderName(model.root))")
                            .font(.edithText(.headline)).lineLimit(1).truncationMode(.middle)
                        Text(
                            model.scannedEntries == 0
                                ? "Starting the scan…"
                                : "\(model.scannedEntries.formatted()) items measured so far"
                        )
                        .font(.edithText(.caption)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    }
                    Spacer(minLength: 0)
                }
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(DashSkin.accent(dark))
                    .accessibilityLabel("Measuring")
                Text(
                    "You can leave this page. The scan keeps going and the map is ready when you come back."
                )
                .font(.edithText(.caption)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(UIScale.pt(16))
            .frame(maxWidth: .infinity, alignment: .leading)
            .edithSurface(cornerRadius: 14)
            PageSkeleton(layout: .analytics)
        }
    }

    private var failedState: some View {
        PageEmptyState(
            icon: .warning,
            title: "This folder could not be scanned",
            message: model.error ?? "The scan stopped before it finished.",
            primary: PageAction(
                "Try again", icon: .refresh, identifier: "blitztree.retry"
            ) {
                if let root = model.root { model.scan(root, remember: false) }
            },
            secondary: PageAction("Choose another folder…", identifier: "blitztree.choose") {
                chooseFolder()
            },
            footnote:
                "If macOS blocked access, allow Edith in System Settings > Privacy & Security > Files and Folders."
        )
        .frame(minHeight: emptyHeight)
        .pageFillViewport()
    }

    private var cancelledState: some View {
        PageEmptyState(
            icon: .stop,
            title: "Scan stopped",
            message: "No results were kept. Start again whenever you are ready.",
            primary: PageAction(
                "Scan again", icon: .refresh, identifier: "blitztree.retry"
            ) {
                if let root = model.root { model.scan(root, remember: false) }
            },
            secondary: PageAction("Choose another folder…", identifier: "blitztree.choose") {
                chooseFolder()
            }
        )
        .frame(minHeight: emptyHeight)
        .pageFillViewport()
    }

    private var folderBinding: Binding<String> {
        Binding(
            get: { model.root ?? "" },
            set: { path in
                guard !path.isEmpty else { return }
                model.scan(path, remember: false)
            })
    }

    private func folderIsValid(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func folderName(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "the folder" }
        return (path as NSString).lastPathComponent.isEmpty
            ? path : (path as NSString).lastPathComponent
    }

    private func location(_ root: String) -> some View {
        HStack(spacing: UIScale.pt(8)) {
            Button {
                if router?.canGoBack == true {
                    router?.goBack()
                } else {
                    model.back()
                }
            } label: {
                EdithIconView(.chevronLeft)
            }
            .buttonStyle(.edith(.toolbar))
            .disabled((router?.canGoBack != true && model.history.isEmpty) || model.removing)
            .help("Back to the previous folder")
            .accessibilityLabel("Back")
            EdithIconView(.folder)
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(.secondary)
            Text(root)
                .font(.edithText(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func results(_ report: BlitzTreeReport) -> some View {
        if let root = model.root { location(root) }
        if let error = model.error {
            PageNotice(error, title: "Something went wrong", tone: .warning)
        }
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: UIScale.pt(PageMetrics.cardSpacing)),
                count: compact ? 2 : 4),
            spacing: UIScale.pt(PageMetrics.cardSpacing)
        ) {
            PageMetric(
                title: "Space used", value: bytes(report.summary.allocatedBytes),
                icon: .drive)
            PageMetric(title: "Files", value: report.summary.fileCount.formatted(), icon: .doc)
            PageMetric(
                title: "Folders", value: report.summary.directoryCount.formatted(),
                icon: .folder)
            PageMetric(
                title: "Scan time", value: String(format: "%.1f s", report.scanSeconds),
                icon: .clock)
        }
        if !report.coverage.complete {
            PageNotice(
                Self.coverageMessage(report.coverage), title: "Some items were skipped",
                tone: .warning)
        }
        PagePanel {
            PageSectionHeader(
                model.removing ? "Moving to the Trash…" : "Folder overview",
                subtitle: "Click a folder to look inside it."
            ) {
                EdithSegmentedPicker(
                    "Visualization", selection: $model.rings, options: [false, true],
                    label: { $0 ? "Rings" : "Treemap" }
                )
                .frame(width: UIScale.pt(176))
            }
        } content: {
            Group {
                if model.rings {
                    BlitzTreeRings(report: report) { entry in activate(entry) }
                } else {
                    BlitzTreeMap(report: report) { entry in activate(entry) }
                }
            }
            .frame(height: UIScale.pt(compact ? 240 : 300))
            .disabled(model.removing)
            Text(
                "Sizes are space allocated on disk, which is not always what you get back after deleting."
            )
            .font(.edithText(.caption))
            .foregroundStyle(.secondary)
        }
        PagePanel {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                EdithSegmentedPicker(
                    "Show", selection: $model.list, options: BlitzTreeList.allCases,
                    label: { $0.rawValue }
                )
                .frame(maxWidth: UIScale.pt(560))
                if model.list == .candidates {
                    Text(
                        "Large items that are often safe to remove, such as caches and build output. Reveal each one in Finder to check before moving it to the Trash.\(report.report.truncated ? " Showing the largest 200." : "")"
                    )
                    .font(.edithText(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        } content: {
            entryList(model.list.entries(report))
        }
    }

    static func coverageMessage(_ coverage: BlitzTreeReport.Coverage) -> String {
        var parts: [String] = []
        if coverage.errors > 0 {
            parts.append(
                coverage.errors == 1
                    ? "1 item could not be read" : "\(coverage.errors) items could not be read")
        }
        if coverage.skippedCloudDirectories > 0 {
            parts.append(
                coverage.skippedCloudDirectories == 1
                    ? "1 iCloud folder was skipped"
                    : "\(coverage.skippedCloudDirectories) iCloud folders were skipped")
        }
        if coverage.skippedMountPoints > 0 {
            parts.append(
                coverage.skippedMountPoints == 1
                    ? "1 other drive was skipped"
                    : "\(coverage.skippedMountPoints) other drives were skipped")
        }
        let detail =
            parts.isEmpty
            ? "Part of this folder could not be measured" : parts.joined(separator: ", ")
        return detail.prefix(1).uppercased() + detail.dropFirst()
            + ", so the totals may be a little low."
    }

    @ViewBuilder private func entryList(_ entries: [BlitzTreeReport.Entry]) -> some View {
        if entries.isEmpty {
            Text(
                model.list == .candidates
                    ? "Nothing here is large enough (50 MB or more) to suggest cleaning up."
                    : "This folder is empty."
            )
            .font(.edithText(.callout))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, UIScale.pt(24))
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider() }
                    entryRow(entry)
                }
            }
        }
    }

    private func entryRow(_ entry: BlitzTreeReport.Entry) -> some View {
        HStack(spacing: UIScale.pt(12)) {
            EdithIconView(entry.isDirectory ? .folder : .doc)
                .font(.system(size: UIScale.pt(14)))
                .foregroundStyle(entry.isDirectory ? DashSkin.accent(dark) : Color.secondary)
                .frame(width: UIScale.pt(20))
            Button {
                activate(entry)
            } label: {
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text(entry.name).font(.edithText(.body)).fontWeight(.medium).lineLimit(1)
                    Text(entry.reason ?? entry.path)
                        .font(.edithText(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))
            .help(entry.isDirectory ? "Open this folder" : "Show in Finder")
            if !entry.complete {
                EdithIconView(.warning)
                    .foregroundStyle(.orange)
                    .help("This entry was only partially scanned")
            }
            Text(bytes(entry.allocatedBytes))
                .font(.edithText(.callout)).fontWeight(.medium).monospacedDigit()
                .frame(minWidth: UIScale.pt(80), alignment: .trailing)
                .fixedSize()
            HStack(spacing: UIScale.pt(4)) {
                Button {
                    reveal(entry)
                } label: {
                    EdithIconView(.search)
                }
                .buttonStyle(.edith(.iconOnly))
                .help("Show in Finder")
                .accessibilityLabel("Show \(entry.name) in Finder")
                Button {
                    pendingRemoval = entry
                } label: {
                    EdithIconView(.trash)
                }
                .buttonStyle(.edith(.iconOnly))
                .help(
                    model.removing
                        ? "Wait for the current move to finish."
                        : "Move to the Trash. You can put it back."
                )
                .accessibilityLabel("Move \(entry.name) to the Trash")
                .disabled(model.removing)
            }
        }
        .padding(.vertical, UIScale.pt(8))
    }

    private func chooseFolder() { model.chooseFolder() }

    private func activate(_ entry: BlitzTreeReport.Entry) {
        if entry.isDirectory { model.scan(entry.path) } else { reveal(entry) }
    }

    private func reveal(_ entry: BlitzTreeReport.Entry) {
        model.reveal(entry.path)
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}

struct BlitzTreeSettings: View {
    var body: some View {
        Form {
            Section("Disk space") {
                SettingsRow(
                    BlitzTreePage.title,
                    subtitle:
                        "Open Disk Map from the sidebar, choose a folder, and Edith draws what takes the most space. Nothing is deleted unless you move an item to the Trash."
                )
            }
        }
        .settingsForm()
    }
}

enum BlitzTreePresentation: Equatable {
    case intro
    case scanning
    case failed
    case cancelled
    case results

    init(hasRoot: Bool, hasReport: Bool, scanning: Bool, hasError: Bool) {
        if hasReport {
            self = .results
        } else if scanning {
            self = .scanning
        } else if !hasRoot {
            self = .intro
        } else if hasError {
            self = .failed
        } else {
            self = .cancelled
        }
    }
}
