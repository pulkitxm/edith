import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

private enum CleanerPendingClean: Equatable {
    case all
    case category(String)

    var categoryID: String? {
        if case .category(let id) = self { return id }
        return nil
    }
}

struct CleanerCard: View {
    let dark: Bool
    let compact: Bool
    let model: CleanerModel
    let pickDrives: (CleanerDrivePicker) -> Void
    @State private var pendingClean: CleanerPendingClean?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .confirmationDialog(
                "Move \(pendingCount) items to the Trash?",
                isPresented: Binding(
                    get: { pendingClean != nil }, set: { if !$0 { pendingClean = nil } }),
                titleVisibility: .visible, presenting: pendingClean
            ) { pending in
                Button(
                    "Move \(JunkScanner.format(pendingBytes)) to the Trash", role: .destructive
                ) {
                    model.clean(categoryID: pending.categoryID)
                }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                Text(
                    pending == .all
                        ? "\(pendingCount) selected items (\(JunkScanner.format(pendingBytes))) go to the Trash, so you can restore them until you empty it. Worktrees are pruned from their repository; their branches stay."
                        : "\(pendingCount) selected items in this category (\(JunkScanner.format(pendingBytes))) go to the Trash, so you can restore them until you empty it."
                )
            }
    }

    @ViewBuilder private var content: some View {
        switch model.presentation {
        case .firstRun: firstRun
        case .scanning: scanningView
        case .nothingToClean: nothingToClean
        case .results: results
        }
    }

    private var firstRun: some View {
        PageEmptyState(
            icon: .broom,
            title: "Get back disk space",
            message:
                "Cleaner looks through your projects and caches for build output, downloaded packages, old Xcode data and unused git worktrees. You decide what goes.",
            steps: [
                PageGuideStep(
                    icon: .search, title: "1. Scan",
                    detail: "Takes about a minute. It only reads folders and changes nothing."),
                PageGuideStep(
                    icon: .stepTools, title: "2. Review",
                    detail:
                        "See what each item is and how much space it frees. Untick anything to keep."
                ),
                PageGuideStep(
                    icon: .trash, title: "3. Clean",
                    detail:
                        "Selected items move to the Trash, so you can restore them until you empty it."
                ),
            ],
            primary: PageAction(
                "Scan my Mac", icon: .search, identifier: "cleaner.scan"
            ) { pickDrives(.scan) },
            secondary: PageAction("Choose where to search…", identifier: "cleaner.choose") {
                pickDrives(.choose)
            },
            footnote:
                "Most of what it finds is rebuilt automatically the next time a project needs it."
        )
        .scrollIndicators(.never)
    }

    private var nothingToClean: some View {
        PageEmptyState(
            icon: .success,
            title: "Nothing to clean",
            message:
                "The scan found no caches or leftovers worth removing in the places it searched. If your projects live somewhere else, add that folder and scan again.",
            primary: PageAction(
                "Scan again", icon: .refresh, identifier: "cleaner.scan"
            ) {
                pickDrives(.scan)
            },
            secondary: PageAction("Choose where to search…", identifier: "cleaner.choose") {
                pickDrives(.choose)
            },
            footnote: model.lastReclaimed > 0
                ? "Moved \(JunkScanner.format(model.lastReclaimed)) to the Trash. Empty the Trash to free the space."
                : nil
        )
        .scrollIndicators(.never)
    }

    private var scanningView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
                if model.lastReclaimed > 0 { reclaimedNotice }
                scanStatus
                PageSkeleton(layout: .list)
            }
            .padding(.top, UIScale.pt(PageMetrics.pinnedContentTop))
            .pageContent(compact)
        }
        .scrollIndicators(.never)
    }

    private var reclaimedNotice: some View {
        PageNotice(
            "Empty the Trash when you are sure, and the space is yours again.",
            title: "Moved \(JunkScanner.format(model.lastReclaimed)) to the Trash",
            tone: .success)
    }

    private var scanStatus: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
            HStack(alignment: .center, spacing: UIScale.pt(12)) {
                PageGuideBadge(icon: .search, size: 40)
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text(
                        model.lastReclaimed > 0
                            ? "Checking what is left" : "Looking for space you can get back"
                    )
                    .font(.edithText(.headline))
                    Text(model.currentScanLocation ?? "Preparing the scan…")
                        .font(.edithText(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            ProgressView()
                .progressViewStyle(.linear)
                .tint(DashSkin.accent(dark))
                .accessibilityLabel("Scanning")
            Divider()
            searchedRow(changeable: false)
            Text(
                "Nothing is changed while it scans. You review everything before anything is removed."
            )
            .font(.edithText(.caption)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(UIScale.pt(16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .edithSurface(cornerRadius: 14)
    }

    private var results: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    controls.padding(.bottom, UIScale.pt(PageMetrics.sectionSpacing))
                    listHeader.disabled(model.scanning)
                    Divider()
                    ForEach(model.list.rows) { row in
                        CleanerRowView(row: row, model: model, dark: dark) {
                            pendingClean = .category($0)
                        }
                        .equatable()
                        .disabled(model.scanning)
                    }
                    if !model.list.matchesSearch { noMatches }
                }
                .padding(.top, UIScale.pt(PageMetrics.pinnedContentTop))
                .pageContent(compact)
            }
            .scrollIndicators(.never)
            Divider()
            footer
                .pageGutter(compact)
                .padding(.vertical, UIScale.pt(12))
        }
    }

    private var pendingBytes: Int64 {
        guard let pendingClean else { return 0 }
        return pendingClean.categoryID.map { model.selectedTotal(categoryID: $0) }
            ?? model.selectedTotal
    }

    private var pendingCount: Int {
        guard let pendingClean else { return 0 }
        return pendingClean.categoryID.map { model.selectedItemCount(categoryID: $0) }
            ?? model.selectedItemCount
    }

    @ViewBuilder private var controls: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
            summary
            if model.logsExpanded { logView }
            Group {
                searchBar
                CleanerFilterBar(model: model, dark: dark)
            }
            .disabled(model.scanning)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
            HStack(alignment: .top, spacing: UIScale.pt(12)) {
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    eyebrow("CAN BE RECLAIMED")
                    Text(JunkScanner.format(model.reclaimableTotal))
                        .font(.edithText(.title)).fontWeight(.semibold).monospacedDigit()
                        .contentTransition(.numericText())
                    Text(
                        "Found in \(model.categories.count) \(model.categories.count == 1 ? "category" : "categories"). Open one to see exactly what is inside."
                    )
                    .font(.edithText(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: UIScale.pt(8))
                Button {
                    withAnimation(Motion.animation(Motion.feedback, reduceMotion: reduceMotion)) {
                        model.logsExpanded.toggle()
                    }
                } label: {
                    Label(
                        model.logsExpanded ? "Hide scan log" : "Show scan log",
                        edith: .terminal
                    )
                    .font(.edithText(.caption))
                }
                .buttonStyle(.edith(.borderless))
                .foregroundStyle(DashSkin.accent(dark))
                .help("What the last scan looked at.")
            }
            if model.lastReclaimed > 0 {
                Label(
                    "Moved \(JunkScanner.format(model.lastReclaimed)) to the Trash last time.",
                    edith: .success
                )
                .font(.edithText(.caption)).foregroundStyle(DashSkin.sage)
            }
            Divider()
            searchedRow(changeable: true)
        }
        .padding(UIScale.pt(16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .edithSurface(cornerRadius: 14)
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            ForEach(Array(model.logs.suffix(8).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.edithText(.caption, design: .monospaced))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(UIScale.pt(12))
        .widgetBar(cornerRadius: 10, fill: DashSkin.paper2(dark))
        .clipped()
        .transition(Motion.transition(.opacity, reduceMotion: reduceMotion, preferCrossFade: true))
    }

    private func searchedRow(changeable: Bool) -> some View {
        HStack(alignment: .center, spacing: UIScale.pt(12)) {
            eyebrow(changeable ? "SEARCHED" : "SEARCHING")
            if model.drives.isEmpty && model.customFolders.isEmpty {
                if model.scanning {
                    SkeletonGroup {
                        HStack(spacing: UIScale.pt(8)) {
                            SkeletonBlock(width: 132, height: 24, corner: 12)
                            SkeletonBlock(width: 96, height: 24, corner: 12)
                        }
                    }
                } else {
                    Text("No drives selected")
                        .font(.edithText(.caption)).foregroundStyle(.secondary)
                }
            } else {
                WrapHStack(spacing: UIScale.pt(8), lineSpacing: UIScale.pt(8)) {
                    ForEach(model.drives) { drive in
                        CleanerLocationChip(
                            icon: drive.isExternal ? .driveExternal : .drive,
                            title: drive.name,
                            detail: JunkScanner.format(drive.totalBytes), dark: dark)
                    }
                    ForEach(model.customFolders.filter { model.isDriveSelected($0) }, id: \.self) {
                        folder in
                        CleanerLocationChip(
                            icon: .folder,
                            title: (folder as NSString).lastPathComponent, detail: nil, dark: dark
                        )
                        .help((folder as NSString).abbreviatingWithTildeInPath)
                    }
                }
            }
            Spacer(minLength: 0)
            if changeable {
                Button("Change…") { pickDrives(.choose) }
                    .font(.edithText(.caption)).buttonStyle(.edith(.borderless))
                    .foregroundStyle(DashSkin.accent(dark)).disabled(model.scanning)
                    .help("Choose which drives and folders are searched on the next scan.")
            }
        }
    }

    private var searchBar: some View {
        SearchField(
            placeholder: "Filter categories and items",
            text: Binding(get: { model.search }, set: { model.search = $0 }))
    }

    private var listHeader: some View {
        HStack(spacing: UIScale.pt(12)) {
            Button {
                model.toggleAll()
            } label: {
                CleanerCheckbox(selection: model.overallSelection, dark: dark)
            }
            .buttonStyle(.edith(.borderless))
            .accessibilityLabel("Select all items")
            Text("Select all").font(.edithText(.callout)).fontWeight(.medium)
            Spacer(minLength: UIScale.pt(8))
            Text(selectionSummary)
                .font(.edithText(.caption)).monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, UIScale.pt(CleanerRowMetrics.inset))
        .padding(.vertical, UIScale.pt(8))
    }

    private var noMatches: some View {
        Label("No items match these filters", edith: .search)
            .font(.edithText(.callout))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, UIScale.pt(32))
    }

    private var selectionSummary: String {
        let selected = "\(model.selectedItemCount) of \(model.totalItemCount) selected"
        let hidden = model.hiddenItemCount
        return hidden > 0 ? selected + " · \(hidden) hidden by filters" : selected
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: UIScale.pt(16)) {
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                if model.cleaningInProgress {
                    HStack(spacing: UIScale.pt(8)) {
                        ProgressView().controlSize(.small)
                        Text("Moving \(JunkScanner.format(model.selectedTotal)) to the Trash…")
                            .font(.edithText(.headline)).monospacedDigit()
                    }
                    Text(
                        "This takes a moment for large folders. The list refreshes when it is done."
                    )
                    .font(.edithText(.caption)).foregroundStyle(.secondary)
                } else {
                    Text(
                        model.selectedTotal > 0
                            ? "\(JunkScanner.format(model.selectedTotal)) selected"
                            : "Nothing selected"
                    )
                    .font(.edithText(.headline)).monospacedDigit()
                    Text(
                        model.selectedTotal > 0
                            ? "You confirm first, and you can restore everything from the Trash."
                            : "Tick the items you want to remove."
                    )
                    .font(.edithText(.caption)).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .layoutPriority(1)
            Spacer(minLength: UIScale.pt(8))
            Button {
                pendingClean = .all
            } label: {
                Label("Move to Trash", edith: .trash)
                    .font(.edithText(.body)).fontWeight(.medium)
            }
            .buttonStyle(.edith(.primary))
            .controlSize(.large)
            .disabled(model.scanning || model.selectedTotal == 0)
            .fixedSize()
            .help(
                model.selectedTotal == 0
                    ? "Tick at least one item above to enable cleaning."
                    : "You will be asked to confirm. Nothing is deleted permanently."
            )
            .accessibilityIdentifier("cleaner.clean")
        }
    }
}

enum CleanerRowMetrics {
    static let inset = 8.0
    static let checkbox = 18.0
    static let spacing = 12.0
    static let chevron = 18.0
    static let size = 80.0
    static let age = 72.0
    static let action = 44.0
    static var itemIndent: Double { inset + checkbox + spacing }
}

private struct CleanerCheckbox: View {
    let selection: JunkSelection
    let dark: Bool

    var body: some View {
        EdithIconView(CleanerRowView.checkbox(selection))
            .font(.system(size: UIScale.pt(14)))
            .foregroundStyle(
                selection == .none
                    ? AnyShapeStyle(.secondary) : AnyShapeStyle(DashSkin.accent(dark))
            )
            .frame(
                width: UIScale.pt(CleanerRowMetrics.checkbox),
                height: UIScale.pt(CleanerRowMetrics.checkbox))
    }
}

private struct CleanerLocationChip: View {
    let icon: EdithIcon
    let title: String
    let detail: String?
    let dark: Bool

    var body: some View {
        HStack(spacing: UIScale.pt(6)) {
            EdithIconView(icon)
                .font(.system(size: UIScale.pt(10)))
                .foregroundStyle(.secondary)
            Text(title).font(.edithText(.caption)).fontWeight(.medium).lineLimit(1)
            if let detail {
                Text(detail).font(.edithText(.caption)).monospacedDigit()
                    .foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, UIScale.pt(10))
        .frame(height: UIScale.pt(24))
        .background(Color.primary.opacity(dark ? 0.08 : 0.05), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

private struct CleanerRowView: View, Equatable {
    let row: CleanerRow
    let model: CleanerModel
    let dark: Bool
    let onClean: (String) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.dark == rhs.dark
    }

    static func checkbox(_ selection: JunkSelection) -> EdithIcon {
        switch selection {
        case .all: .checkboxOn
        case .some: .checkboxMixed
        case .none: .checkbox
        }
    }

    var body: some View {
        switch row.kind {
        case .category(let category):
            CleanerCategoryHeader(category: category, model: model, dark: dark, onClean: onClean)
        case .itemFilter(let categoryID, let count):
            SearchField(
                placeholder: "Filter \(count) items",
                text: Binding(
                    get: { model.itemFilters[categoryID] ?? "" },
                    set: { model.setItemFilter($0, categoryID: categoryID) }),
                compact: true
            )
            .padding(.leading, UIScale.pt(CleanerRowMetrics.itemIndent))
            .padding(.trailing, UIScale.pt(CleanerRowMetrics.inset))
            .padding(.bottom, UIScale.pt(8))
        case .item(let item):
            CleanerItemLine(item: item, model: model, dark: dark)
        case .divider:
            Divider().padding(.top, UIScale.pt(4))
        }
    }
}

private struct CleanerCategoryHeader: View {
    let category: CleanerCategoryRow
    let model: CleanerModel
    let dark: Bool
    let onClean: (String) -> Void
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selection: JunkSelection { model.categorySelection(category.id) }
    private var selectedCount: Int { model.selectedItemCount(categoryID: category.id) }

    var body: some View {
        HStack(spacing: UIScale.pt(CleanerRowMetrics.spacing)) {
            Button {
                model.toggleCategory(category.id)
            } label: {
                CleanerCheckbox(selection: selection, dark: dark)
            }
            .buttonStyle(.edith(.borderless))
            .accessibilityLabel("Select \(category.name)")
            Button {
                withAnimation(Motion.animation(Motion.feedback, reduceMotion: reduceMotion)) {
                    model.toggleExpand(category.id)
                }
            } label: {
                HStack(spacing: UIScale.pt(CleanerRowMetrics.spacing)) {
                    EdithIconView(.chevronRight)
                        .font(.system(size: UIScale.pt(10), weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(category.expanded ? 90 : 0))
                        .frame(width: UIScale.pt(CleanerRowMetrics.chevron))
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        Text(category.name).font(.edithText(.body)).fontWeight(.medium)
                            .lineLimit(1)
                        Text(category.detail).font(.edithText(.caption))
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: UIScale.pt(8))
                    Text(category.itemCount == 1 ? "1 item" : "\(category.itemCount) items")
                        .font(.edithText(.caption)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Text(category.sizeText)
                        .font(.edithText(.callout)).fontWeight(.medium).monospacedDigit()
                        .frame(minWidth: UIScale.pt(CleanerRowMetrics.size), alignment: .trailing)
                        .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))
            .accessibilityValue(category.expanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows the items in this category")
            Button("Clean") { onClean(category.id) }
                .font(.edithText(.caption)).fontWeight(.medium)
                .foregroundStyle(DashSkin.accent(dark))
                .buttonStyle(.edith(.borderless))
                .frame(width: UIScale.pt(CleanerRowMetrics.action), alignment: .trailing)
                .disabled(selectedCount == 0)
                .help(
                    selectedCount == 0
                        ? "Tick items in this category to clean them."
                        : "Move the selected items in \(category.name) to the Trash.")
        }
        .padding(.horizontal, UIScale.pt(CleanerRowMetrics.inset))
        .padding(.vertical, UIScale.pt(10))
        .background(
            RoundedRectangle(cornerRadius: UIScale.pt(8))
                .fill(hover ? Color.primary.opacity(0.05) : .clear)
        )
        .onHover { hover = $0 }
    }
}

private struct CleanerItemLine: View {
    let item: CleanerItemRow
    let model: CleanerModel
    let dark: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            model.toggleItem(categoryID: item.categoryID, itemID: item.id)
        } label: {
            HStack(spacing: UIScale.pt(CleanerRowMetrics.spacing)) {
                let selected = model.isSelected(categoryID: item.categoryID, itemID: item.id)
                CleanerCheckbox(selection: selected ? .all : .none, dark: dark)
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text(item.name).font(.edithText(.callout)).lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .help(item.path.path)
                    if let branch = item.branch { worktreeLine(branch) }
                }
                Spacer(minLength: UIScale.pt(8))
                if let age = item.ageText {
                    Text(age)
                        .font(.edithText(.caption)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: UIScale.pt(CleanerRowMetrics.age), alignment: .trailing)
                        .fixedSize()
                        .help("Last edited")
                }
                Text(item.sizeText)
                    .font(.edithText(.callout)).monospacedDigit()
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .frame(minWidth: UIScale.pt(CleanerRowMetrics.size), alignment: .trailing)
                    .fixedSize()
                Color.clear.frame(width: UIScale.pt(CleanerRowMetrics.action), height: 1)
            }
            .padding(.leading, UIScale.pt(CleanerRowMetrics.itemIndent))
            .padding(.trailing, UIScale.pt(CleanerRowMetrics.inset))
            .padding(.vertical, UIScale.pt(6))
            .background(
                RoundedRectangle(cornerRadius: UIScale.pt(8))
                    .fill(hovering ? Color.primary.opacity(0.05) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.path])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path.path, forType: .string)
            }
        }
    }

    private func worktreeLine(_ branch: String) -> some View {
        HStack(spacing: UIScale.pt(6)) {
            EdithIconView(.quinjet)
                .font(.system(size: UIScale.pt(9)))
            Text(branch)
                .font(.edithText(.caption, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
            ForEach(item.badges, id: \.self) { badge in
                Text(badge)
                    .font(.edithText(.caption2)).fontWeight(.semibold)
                    .lineLimit(1)
                    .padding(.horizontal, UIScale.pt(6))
                    .frame(height: UIScale.pt(16))
                    .background(Color.primary.opacity(0.07), in: Capsule())
                    .fixedSize()
            }
        }
        .foregroundStyle(.secondary)
    }
}

struct DrivePickerSheet: View {
    let model: CleanerModel
    let dark: Bool
    let confirmTitle: String
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                Text("Choose where to search")
                    .font(.edithText(.title3)).fontWeight(.semibold)
                Text(
                    "Selected drives and folders are searched for build output, dependencies and git worktrees. System caches always come from your home folder."
                )
                .font(.edithText(.callout)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, UIScale.pt(20)).padding(.top, UIScale.pt(20))
            .padding(.bottom, UIScale.pt(16))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                    eyebrow("DRIVES")
                    if model.driveOptions.isEmpty, model.loadingDriveOptions {
                        ForEach(0..<2, id: \.self) { index in
                            DrivePickerRowSkeleton(index: index, dark: dark)
                        }
                    } else if model.driveOptions.isEmpty {
                        Text("No drives are available. Add a folder below instead.")
                            .font(.edithText(.callout))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, UIScale.pt(8))
                    }
                    ForEach(model.driveOptions) { drive in
                        Button {
                            model.toggleDrive(drive.id)
                        } label: {
                            locationRow(
                                selected: model.isDriveSelected(drive.id),
                                icon: drive.isExternal ? .driveExternal : .drive,
                                title: drive.name,
                                detail: "\(JunkScanner.format(drive.totalBytes)) capacity",
                                trailingSpace: false)
                        }
                        .buttonStyle(.edith(.borderless))
                        .accessibilityLabel(drive.name)
                        .accessibilityValue(
                            model.isDriveSelected(drive.id) ? "Selected" : "Not selected")
                    }
                    eyebrow("FOLDERS").padding(.top, UIScale.pt(8))
                    ForEach(model.customFolders, id: \.self) { folder in
                        folderRow(folder)
                    }
                    Button {
                        chooseFolder()
                    } label: {
                        Label("Add folder…", edith: .plus)
                            .font(.edithText(.callout))
                    }
                    .buttonStyle(.edith(.secondary))
                    .help(
                        "Search a folder that is not on one of the drives above, such as a project directory."
                    )
                }
                .padding(UIScale.pt(20))
            }
            .frame(maxHeight: UIScale.pt(320))
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(spacing: UIScale.pt(8)) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.edith(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) {
                    dismiss()
                    onConfirm()
                }
                .buttonStyle(.edith(.primary))
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("cleaner.picker.confirm")
            }
            .padding(.horizontal, UIScale.pt(20)).padding(.vertical, UIScale.pt(16))
        }
        .frame(width: UIScale.pt(440))
        .background(DashSkin.paper(dark))
        .onAppear { model.loadDriveOptions() }
    }

    private func locationRow(
        selected: Bool, icon: EdithIcon, title: String, detail: String, trailingSpace: Bool
    ) -> some View {
        HStack(spacing: UIScale.pt(12)) {
            CleanerCheckbox(selection: selected ? .all : .none, dark: dark)
            EdithIconView(icon)
                .font(.system(size: UIScale.pt(13)))
                .foregroundStyle(.secondary)
                .frame(width: UIScale.pt(18))
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(title).font(.edithText(.body)).fontWeight(.medium).lineLimit(1)
                Text(detail)
                    .font(.edithText(.caption)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if trailingSpace {
                Color.clear.frame(width: UIScale.pt(28), height: UIScale.pt(28))
            }
        }
        .padding(.horizontal, UIScale.pt(12)).padding(.vertical, UIScale.pt(8))
        .frame(minHeight: UIScale.pt(48))
        .edithSurface(cornerRadius: 10)
        .contentShape(Rectangle())
    }

    private func folderRow(_ folder: String) -> some View {
        ZStack(alignment: .trailing) {
            Button {
                model.toggleDrive(folder)
            } label: {
                locationRow(
                    selected: model.isDriveSelected(folder), icon: .folder,
                    title: (folder as NSString).lastPathComponent,
                    detail: (folder as NSString).abbreviatingWithTildeInPath,
                    trailingSpace: true)
            }
            .buttonStyle(.edith(.borderless))
            .accessibilityLabel((folder as NSString).lastPathComponent)
            .accessibilityValue(model.isDriveSelected(folder) ? "Selected" : "Not selected")
            Button {
                model.removeCustomFolder(folder)
            } label: {
                EdithIconView(.removeFilled)
            }
            .buttonStyle(.edith(.iconOnly))
            .padding(.trailing, UIScale.pt(10))
            .help("Stop searching this folder")
            .accessibilityLabel("Remove \((folder as NSString).lastPathComponent)")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder to search for project leftovers"
        if panel.runModal() == .OK, let url = panel.url {
            model.addCustomFolder(url.path)
        }
    }
}

private struct CleanerFilterBar: View {
    let model: CleanerModel
    let dark: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: UIScale.pt(20)) {
                ageControl(labelWidth: nil)
                sortControl(labelWidth: nil)
                Spacer(minLength: UIScale.pt(16))
                protectToggle
            }
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                ageControl(labelWidth: 104)
                HStack(alignment: .center, spacing: UIScale.pt(16)) {
                    sortControl(labelWidth: 104)
                    Spacer(minLength: 0)
                }
                protectToggle
            }
        }
    }

    private func ageControl(labelWidth: Double?) -> some View {
        HStack(alignment: .center, spacing: UIScale.pt(8)) {
            caption("UNTOUCHED FOR", width: labelWidth)
            EdithSegmentedPicker(
                "Untouched for",
                selection: Binding(get: { model.age }, set: { model.setAge($0) }),
                options: CleanerAge.allCases, label: \.label
            )
            .frame(width: UIScale.pt(288))
            InfoDot(
                "Only show project folders and worktrees whose sources and git index have not changed for this long. Build output does not count as an edit. Global caches always show."
            )
        }
    }

    private func sortControl(labelWidth: Double?) -> some View {
        HStack(alignment: .center, spacing: UIScale.pt(8)) {
            caption("SORT", width: labelWidth)
            EdithSegmentedPicker(
                "Sort",
                selection: Binding(get: { model.filters.sort }, set: { model.setSort($0) }),
                options: CleanerSort.allCases, label: \.label
            )
            .frame(width: UIScale.pt(160))
        }
    }

    private var protectToggle: some View {
        Button {
            model.setProtectDirty(!model.filters.protectDirty)
        } label: {
            HStack(spacing: UIScale.pt(8)) {
                CleanerCheckbox(selection: model.filters.protectDirty ? .all : .none, dark: dark)
                Text("Keep worktrees with uncommitted changes")
                    .font(.edithText(.callout))
            }
            .fixedSize()
        }
        .buttonStyle(.edith(.borderless))
        .accessibilityAddTraits(model.filters.protectDirty ? .isSelected : [])
        .help("Worktrees with work you have not committed are left out of the results.")
    }

    @ViewBuilder private func caption(_ text: String, width: Double?) -> some View {
        if let width {
            eyebrow(text).frame(width: UIScale.pt(width), alignment: .leading)
        } else {
            eyebrow(text).fixedSize()
        }
    }
}

private struct DrivePickerRowSkeleton: View {
    let index: Int
    let dark: Bool

    var body: some View {
        SkeletonGroup {
            HStack(spacing: UIScale.pt(12)) {
                SkeletonBlock(width: 18, height: 18, corner: 4)
                SkeletonBlock(width: 18, height: 16, corner: 4)
                VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                    SkeletonBlock(width: index.isMultiple(of: 2) ? 118 : 156, height: 11)
                    SkeletonBlock(width: 96, height: 8)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, UIScale.pt(12))
            .padding(.vertical, UIScale.pt(8))
            .frame(minHeight: UIScale.pt(48))
            .edithSurface(cornerRadius: 10)
        }
    }
}
