import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct BlitzTreePage: View {
    static let title = "Disk Map"
    @State var model: BlitzTreeModel
    @State private var pendingRemoval: BlitzTreeReport.Entry?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.windowRouter) private var router

    var body: some View {
        PageScaffold {
            PageHeader(
                title: { Text(Self.title) },
                trailing: { headerActions },
                accessory: { PageSubtitle(subtitle) })
        } content: {
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                if let root = model.root, presentation == .results || presentation == .scanning {
                    navigation(root)
                }
                if let error = model.error, presentation == .results {
                    PageNotice(error, title: "Something went wrong", tone: .warning)
                }
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
        }
        .navigationRoute("list", selection: $model.list)
        .navigationRoute("folder", selection: folderBinding, isValid: folderIsValid)
        .onDisappear { model.cancel() }
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

    private var subtitle: String {
        switch presentation {
        case .intro, .cancelled, .failed:
            "Pick a folder to see which files and folders take the most space. Scanning never changes anything."
        case .scanning:
            "Measuring the folder. You can cancel at any time."
        case .results:
            "Bigger blocks use more space. Click a folder to look inside it."
        }
    }

    @ViewBuilder private var headerActions: some View {
        HStack(spacing: UIScale.pt(8)) {
            if model.scanning {
                Button("Cancel scan", action: model.cancel).buttonStyle(.edith(.secondary))
            } else if let root = model.root, model.report != nil {
                Button("Rescan", systemImage: "arrow.clockwise") {
                    model.scan(root, remember: false)
                }
                .buttonStyle(.edith(.secondary))
                .disabled(model.removing)
                .help(
                    model.removing
                        ? "Wait for the item to finish moving to the Trash."
                        : "Measure this folder again.")
            }
            if presentation != .intro {
                Button("Choose folder…", systemImage: "folder") { chooseFolder() }
                    .buttonStyle(.edith(.primary))
                    .disabled(model.removing)
                    .help(
                        model.removing
                            ? "Wait for the item to finish moving to the Trash."
                            : "Pick a different folder to measure.")
            }
        }
    }

    private var introState: some View {
        PageEmptyState(
            symbolName: "square.grid.3x3.fill",
            title: "See where your space goes",
            message:
                "Disk Map measures a folder and draws it as blocks sized by how much space each file or folder uses.",
            steps: [
                PageGuideStep(
                    symbolName: "folder", title: "Pick a folder",
                    detail: "Start with your home folder or any drive. Nothing is changed."),
                PageGuideStep(
                    symbolName: "square.grid.3x3.fill", title: "Explore",
                    detail: "Click a block to open that folder. The largest items are listed below."
                ),
                PageGuideStep(
                    symbolName: "trash", title: "Free up space",
                    detail:
                        "Review cleanup candidates, reveal them in Finder, or move them to the Trash."
                ),
            ],
            primary: PageAction(
                "Choose a folder…", symbolName: "folder", identifier: "blitztree.choose"
            ) {
                chooseFolder()
            },
            secondary: PageAction("Scan my home folder", identifier: "blitztree.scan-home") {
                model.scan(NSHomeDirectory())
            },
            footnote: "Large folders can take a minute. Cloud-only files are skipped.")
    }

    private var scanningState: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                Text("Scanning \((model.root ?? "") as NSString)").font(.edithText(.headline))
                    .lineLimit(1).truncationMode(.middle)
                Text("\(model.scannedEntries.formatted()) entries measured so far.")
                    .font(.edithText(.callout)).foregroundStyle(.secondary).monospacedDigit()
            }
            PageSkeleton(layout: .analytics)
        }
    }

    private var failedState: some View {
        PageEmptyState(
            symbolName: "exclamationmark.triangle",
            title: "This folder could not be scanned",
            message: model.error ?? "The scan stopped before it finished.",
            primary: PageAction(
                "Try again", symbolName: "arrow.clockwise", identifier: "blitztree.retry"
            ) {
                if let root = model.root { model.scan(root, remember: false) }
            },
            secondary: PageAction("Choose another folder…", identifier: "blitztree.choose") {
                chooseFolder()
            },
            footnote:
                "If macOS blocked access, allow Edith in System Settings > Privacy & Security > Files and Folders."
        )
    }

    private var cancelledState: some View {
        PageEmptyState(
            symbolName: "stop.circle",
            title: "Scan stopped",
            message: "No results were kept. Start again whenever you are ready.",
            primary: PageAction(
                "Scan again", symbolName: "arrow.clockwise", identifier: "blitztree.retry"
            ) {
                if let root = model.root { model.scan(root, remember: false) }
            },
            secondary: PageAction("Choose another folder…", identifier: "blitztree.choose") {
                chooseFolder()
            })
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

    private func navigation(_ root: String) -> some View {
        HStack {
            Button("Back", systemImage: "chevron.left") {
                if router?.canGoBack == true {
                    router?.goBack()
                } else {
                    model.back()
                }
            }
            .disabled((router?.canGoBack != true && model.history.isEmpty) || model.removing)
            Text(root)
                .font(.system(size: UIScale.pt(12), design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
        }
    }

    @ViewBuilder private func results(_ report: BlitzTreeReport) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: UIScale.pt(130)), spacing: UIScale.pt(24))],
            alignment: .leading
        ) {
            metric("Allocated", bytes(report.summary.allocatedBytes))
            metric("Files", report.summary.fileCount.formatted())
            metric("Folders", report.summary.directoryCount.formatted())
            metric("Scan time", String(format: "%.1f s", report.scanSeconds))
        }
        if !report.coverage.complete {
            Label(
                "Partial scan: \(report.coverage.errors) items could not be read, and \(report.coverage.skippedCloudDirectories) cloud folders and \(report.coverage.skippedMountPoints) other drives were skipped, so totals may be low.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.edithText(.callout))
            .foregroundStyle(.orange)
        }
        HStack {
            PageSectionHeader(
                model.removing ? "Moving to the Trash…" : "Folder overview",
                subtitle: "Bigger blocks use more space.")
            Spacer()
            EdithSegmentedPicker(
                "Visualization", selection: $model.rings, options: [false, true],
                label: { $0 ? "Rings" : "Treemap" }
            )
            .labelsHidden()
            .frame(width: UIScale.pt(180))
        }
        Group {
            if model.rings {
                BlitzTreeRings(report: report) { entry in activate(entry) }
            } else {
                BlitzTreeMap(report: report) { entry in activate(entry) }
            }
        }
        .frame(height: UIScale.pt(280))
        .disabled(model.removing)
        Text(
            "Sizes are space allocated on disk, which is not always what you get back after deleting. Click a folder to scan inside it."
        )
        .font(.edithText(.caption))
        .foregroundStyle(.secondary)
        EdithSegmentedPicker(
            "Show", selection: $model.list, options: BlitzTreeList.allCases, label: { $0.rawValue })
        if model.list == .candidates {
            Text(
                "\(report.report.candidateCount) large items that are often safe to remove, such as caches and build output. Reveal each one in Finder to check before moving it to the Trash.\(report.report.truncated ? " Showing the largest 200." : "")"
            )
            .font(.edithText(.callout))
            .foregroundStyle(.secondary)
        }
        let entries = model.list.entries(report)
        if entries.isEmpty {
            Text(
                model.list == .candidates
                    ? "Nothing here is large enough (50 MB or more) to suggest cleaning up."
                    : "This folder is empty."
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
                            Text(entry.name).fontWeight(.medium).lineLimit(1)
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
                    if !entry.complete {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .help("This entry was only partially scanned")
                    }
                    Text(bytes(entry.allocatedBytes)).monospacedDigit()
                    Button("Reveal", systemImage: "arrow.up.forward.square") { reveal(entry) }
                        .labelStyle(.iconOnly)
                        .help("Show in Finder")
                    Button("Move to Trash", systemImage: "trash") { pendingRemoval = entry }
                        .labelStyle(.iconOnly)
                        .help(
                            model.removing
                                ? "Wait for the current move to finish."
                                : "Move to the Trash. You can put it back."
                        )
                        .disabled(model.removing)
                }
                .padding(.vertical, UIScale.pt(10))
                Divider()
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            Text(label).font(.edithText(.caption)).foregroundStyle(.secondary)
            Text(value).font(.edithText(.title2)).monospacedDigit()
        }
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
    static let summaryName = BlitzTreePage.title

    var body: some View {
        Form {
            Section("Disk space") {
                LabeledContent("Extension", value: Self.summaryName)
                Text(
                    "Open Disk Map from the sidebar, choose a folder, and Edith draws what takes the most space. Nothing is deleted unless you move an item to the Trash."
                )
                .settingsCaption()
            }
        }
        .edithForm()
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
