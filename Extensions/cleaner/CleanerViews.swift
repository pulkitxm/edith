import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct CleanerCard: View {
    let dark: Bool
    var framed = true
    @State private var model: CleanerModel
    @State private var showDrivePicker = false
    @State private var pickerScans = false
    @State private var confirmClean = false

    init(dark: Bool, framed: Bool = true, model: CleanerModel) {
        self.dark = dark
        self.framed = framed
        _model = State(initialValue: model)
    }

    var body: some View {
        Group {
            if framed {
                PageCard(title: "Reclaim developer space") { content }
            } else {
                content
            }
        }
        .edithSheet(isPresented: $showDrivePicker) {
            DrivePickerSheet(
                model: model, dark: dark, confirmTitle: pickerScans ? "Scan" : "Done"
            ) {
                if pickerScans { model.scan() }
            }
        }
        .confirmationDialog(
            "Clean \(JunkScanner.format(model.selectedTotal))?",
            isPresented: $confirmClean, titleVisibility: .visible
        ) {
            Button("Move \(model.selectedItemCount) items to Trash", role: .destructive) {
                model.clean()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Items go to the Trash, so you can restore them until you empty it. Worktrees are pruned from their repository; their branches stay."
            )
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            if !model.scanned && !model.scanning {
                intro
            } else {
                header
                if model.logsExpanded { logView }
                if model.scanned {
                    drivesView
                    if !model.categories.isEmpty {
                        searchBar
                        CleanerFilterBar(model: model, dark: dark)
                        selectAllRow
                        if model.filteredCategories.isEmpty {
                            Label("No items match these filters", systemImage: "magnifyingglass")
                                .font(.system(size: UIScale.pt(12)))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                        }
                        ForEach(model.filteredCategories) { category in
                            CleanerCategoryRow(model: model, category: category, dark: dark)
                        }
                        footer
                    } else {
                        Text("Nothing to clean. You're already tidy.")
                            .font(.system(size: UIScale.pt(12)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                    }
                }
            }
            if model.lastReclaimed > 0 {
                Text("Reclaimed \(JunkScanner.format(model.lastReclaimed)) last clean.")
                    .font(.system(size: UIScale.pt(11))).foregroundStyle(DashSkin.sage)
            }
        }
    }

    private var intro: some View {
        HStack {
            Text("Scan build caches, package managers, git worktrees and your drives.")
                .font(.system(size: UIScale.pt(12))).foregroundStyle(DashSkin.inkFaint(dark))
            Spacer()
            Button("Scan") { openPicker(scan: true) }
        }
    }

    private var header: some View {
        HStack(spacing: UIScale.pt(8)) {
            if model.scanning {
                SkeletonGroup {
                    SkeletonBlock(width: 52, height: 22, corner: 11)
                }
                Text(model.operationTitle).font(.system(size: UIScale.pt(12))).foregroundStyle(
                    DashSkin.inkSoft(dark))
                Button("Cancel") { model.cancelScan() }
                    .font(.system(size: UIScale.pt(11), weight: .medium)).buttonStyle(
                        .edith(.borderless)
                    )
                    .foregroundStyle(DashSkin.accent(dark))
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) { model.logsExpanded.toggle() }
                } label: {
                    HStack(spacing: UIScale.pt(5)) {
                        Image(systemName: "terminal")
                            .font(.system(size: UIScale.pt(10), weight: .semibold))
                        Text("Logs")
                            .font(.system(size: UIScale.pt(11), weight: .medium))
                        Image(systemName: model.logsExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: UIScale.pt(8), weight: .semibold))
                    }
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .padding(.horizontal, UIScale.pt(9)).padding(.vertical, UIScale.pt(4))
                    .background(DashSkin.paper2(dark), in: Capsule())
                }
                .buttonStyle(.edith(.borderless))
            }
            Spacer()
            if !model.scanning {
                Button("Scan again", systemImage: "arrow.clockwise") { openPicker(scan: true) }
            }
        }
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
            ForEach(Array(model.logs.suffix(8).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: UIScale.pt(10.5), design: .monospaced))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(UIScale.pt(10))
        .widgetBar(cornerRadius: 10, fill: DashSkin.paper2(dark))
        .clipped()
        .transition(.opacity)
    }

    private var drivesView: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            HStack(spacing: UIScale.pt(10)) {
                Text("DRIVES").font(.system(size: UIScale.pt(10), weight: .bold)).tracking(
                    UIScale.pt(0.6)
                )
                .foregroundStyle(DashSkin.inkFaint(dark))
                Spacer()
                Button("Rescan") { model.scan() }
                    .font(.system(size: UIScale.pt(11), weight: .medium)).buttonStyle(
                        .edith(.borderless)
                    )
                    .foregroundStyle(DashSkin.accent(dark)).disabled(model.scanning)
                InfoDot("Cleaning moves items to the Trash, so it stays reversible.")
                Button("Choose drives…") { openPicker(scan: false) }
                    .font(.system(size: UIScale.pt(11))).buttonStyle(.edith(.borderless))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            if model.drives.isEmpty {
                if model.scanning {
                    ForEach(0..<2, id: \.self) { _ in DriveSkeleton(dark: dark) }
                } else {
                    Text("No drives selected.")
                        .font(.system(size: UIScale.pt(11))).foregroundStyle(
                            DashSkin.inkFaint(dark))
                }
            } else {
                ForEach(model.drives) { drive in DriveRow(drive: drive, dark: dark) }
            }
        }
    }

    private var searchBar: some View {
        SearchField(placeholder: "Filter", text: $model.search)
    }

    private var selectAllRow: some View {
        HStack(spacing: UIScale.pt(10)) {
            Button {
                model.toggleAll()
            } label: {
                Image(systemName: selectAllSymbol)
                    .foregroundStyle(
                        model.overallSelection == .none ? .secondary : DashSkin.accent(dark))
            }
            .buttonStyle(.edith(.borderless))
            Text("Select all").font(.system(size: UIScale.pt(12), weight: .medium))
            Spacer()
            Text(selectionSummary)
                .font(.system(size: UIScale.pt(10.5))).foregroundStyle(DashSkin.inkFaint(dark))
        }
        .padding(.vertical, UIScale.pt(4))
    }

    private var selectionSummary: String {
        let selected = "\(model.selectedItemCount) of \(model.totalItemCount) selected"
        let hidden = model.hiddenItemCount
        return hidden > 0 ? selected + " · \(hidden) hidden by filters" : selected
    }

    private var selectAllSymbol: String {
        switch model.overallSelection {
        case .all: "checkmark.square.fill"
        case .some: "minus.square.fill"
        case .none: "square"
        }
    }

    private var footer: some View {
        Button {
            confirmClean = true
        } label: {
            Text(
                model.selectedTotal > 0
                    ? "Clean \(JunkScanner.format(model.selectedTotal))" : "Select items to clean"
            )
            .font(.system(size: UIScale.pt(14), weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, UIScale.pt(9))
        }
        .buttonStyle(.edith(.primary))
        .tint(DashSkin.accent(dark))
        .controlSize(.large)
        .disabled(model.scanning || model.selectedTotal == 0)
        .padding(.top, UIScale.pt(2))
    }

    private func openPicker(scan: Bool) {
        pickerScans = scan
        model.loadDriveOptions()
        showDrivePicker = true
    }
}

private struct DrivePickerSheet: View {
    let model: CleanerModel
    let dark: Bool
    let confirmTitle: String
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(0)) {
            Text("Choose where to search")
                .font(.system(size: UIScale.pt(15), weight: .semibold))
                .padding(.horizontal, UIScale.pt(20)).padding(.top, UIScale.pt(20))
            Text(
                "Selected drives and folders are searched for build output, dependencies and git worktrees. System caches always come from your home folder."
            )
            .font(.system(size: UIScale.pt(11.5))).foregroundStyle(DashSkin.inkFaint(dark))
            .padding(.horizontal, UIScale.pt(20)).padding(.top, UIScale.pt(4))

            ScrollView {
                VStack(spacing: UIScale.pt(6)) {
                    if model.loadingDriveOptions {
                        ForEach(0..<3, id: \.self) { index in
                            DrivePickerRowSkeleton(index: index, dark: dark)
                        }
                    } else if model.driveOptions.isEmpty {
                        Text("No drives are available.")
                            .font(.system(size: UIScale.pt(11.5)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, UIScale.pt(20))
                    }
                    ForEach(model.driveOptions) { drive in
                        Button {
                            model.toggleDrive(drive.id)
                        } label: {
                            HStack(spacing: UIScale.pt(10)) {
                                Image(
                                    systemName: model.isDriveSelected(drive.id)
                                        ? "checkmark.square.fill" : "square"
                                )
                                .foregroundStyle(
                                    model.isDriveSelected(drive.id)
                                        ? DashSkin.accent(dark) : .secondary)
                                Image(
                                    systemName: drive.isExternal
                                        ? "externaldrive.fill" : "internaldrive.fill"
                                )
                                .font(.system(size: UIScale.pt(12))).foregroundStyle(
                                    DashSkin.inkFaint(dark))
                                VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                                    Text(drive.name).font(
                                        .system(size: UIScale.pt(13), weight: .medium))
                                    Text(
                                        "\(JunkScanner.format(drive.totalBytes)) capacity"
                                    )
                                    .font(.system(size: UIScale.pt(10.5), design: .monospaced))
                                    .foregroundStyle(DashSkin.inkFaint(dark))
                                }
                                Spacer()
                            }
                            .padding(.horizontal, UIScale.pt(12)).padding(.vertical, UIScale.pt(8))
                            .widgetBar(cornerRadius: 8, fill: DashSkin.paper2(dark))
                        }
                        .buttonStyle(.edith(.borderless))
                    }
                    if !model.customFolders.isEmpty {
                        Text("FOLDERS").font(.system(size: UIScale.pt(10), weight: .bold)).tracking(
                            UIScale.pt(0.6)
                        )
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, UIScale.pt(6))
                        ForEach(model.customFolders, id: \.self) { folder in
                            folderRow(folder)
                        }
                    }
                    Button {
                        chooseFolder()
                    } label: {
                        HStack(spacing: UIScale.pt(6)) {
                            Image(systemName: "plus.circle")
                            Text("Add folder…")
                        }
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(DashSkin.accent(dark))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, UIScale.pt(4))
                    }
                    .buttonStyle(.edith(.borderless))
                }
                .padding(UIScale.pt(20))
            }
            .frame(maxHeight: UIScale.pt(280))

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(confirmTitle) {
                    dismiss()
                    onConfirm()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, UIScale.pt(20)).padding(.vertical, UIScale.pt(14))
        }
        .frame(width: UIScale.pt(420))
        .background(DashSkin.paper(dark))
        .onAppear { model.loadDriveOptions() }
    }

    private func folderRow(_ folder: String) -> some View {
        ZStack(alignment: .trailing) {
            Button {
                model.toggleDrive(folder)
            } label: {
                HStack(spacing: UIScale.pt(10)) {
                    Image(
                        systemName: model.isDriveSelected(folder)
                            ? "checkmark.square.fill" : "square"
                    )
                    .foregroundStyle(
                        model.isDriveSelected(folder) ? DashSkin.accent(dark) : .secondary)
                    Image(systemName: "folder.fill")
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                    VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                        Text((folder as NSString).lastPathComponent)
                            .font(.system(size: UIScale.pt(13), weight: .medium))
                        Text((folder as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: UIScale.pt(10.5), design: .monospaced))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Color.clear.frame(width: UIScale.pt(28), height: UIScale.pt(28))
                }
                .padding(.horizontal, UIScale.pt(12)).padding(.vertical, UIScale.pt(8))
                .widgetBar(cornerRadius: 8, fill: DashSkin.paper2(dark))
            }
            .buttonStyle(.edith(.borderless))
            Button {
                model.removeCustomFolder(folder)
            } label: {
                Image(systemName: "trash").font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.edith(.borderless))
            .padding(.trailing, UIScale.pt(12))
            .help("Remove this folder")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder to search for project junk"
        if panel.runModal() == .OK, let url = panel.url {
            model.addCustomFolder(url.path)
        }
    }
}

private struct CleanerCategoryRow: View {
    let model: CleanerModel
    let category: JunkCategory
    let dark: Bool
    @State private var itemFilter = ""
    @State private var headerHover = false
    @State private var confirmClean = false

    private var isExpanded: Bool { model.expanded.contains(category.id) }

    private var showItemFilter: Bool { category.items.count > 10 }

    private var visibleItems: [JunkItem] {
        guard !itemFilter.isEmpty else { return category.items }
        let query = itemFilter.lowercased()
        return category.items.filter { $0.name.lowercased().contains(query) }
    }

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            ZStack {
                Button {
                    model.toggleExpand(category.id)
                } label: {
                    HStack(spacing: UIScale.pt(10)) {
                        Color.clear.frame(width: UIScale.pt(28), height: UIScale.pt(28))
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: UIScale.pt(9)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                        VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                            Text(category.name).font(.system(size: UIScale.pt(13), weight: .medium))
                            Text(category.detail).font(.system(size: UIScale.pt(10.5)))
                                .foregroundStyle(DashSkin.inkFaint(dark)).lineLimit(1)
                        }
                        Spacer()
                        Text("\(category.items.count) items")
                            .font(.system(size: UIScale.pt(10))).foregroundStyle(
                                DashSkin.inkFaint(dark))
                        Text(JunkScanner.format(category.sizeBytes))
                            .font(.system(size: UIScale.pt(12), design: .monospaced))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .frame(width: UIScale.pt(72), alignment: .trailing)
                        Text("Clean")
                            .font(.system(size: UIScale.pt(10.5), weight: .medium))
                            .hidden()
                            .frame(minWidth: UIScale.pt(28), minHeight: UIScale.pt(28))
                    }
                    .padding(.horizontal, UIScale.pt(6))
                    .padding(.vertical, UIScale.pt(7))
                    .background(
                        RoundedRectangle(cornerRadius: UIScale.pt(7))
                            .fill(headerHover ? DashSkin.inkFaint(dark).opacity(0.1) : .clear)
                    )
                }
                .buttonStyle(.edith(.borderless))
                .onHover { headerHover = $0 }
                HStack {
                    Button {
                        model.toggleCategory(category.id)
                    } label: {
                        Image(systemName: checkboxSymbol)
                            .foregroundStyle(
                                category.selection == .none ? .secondary : DashSkin.accent(dark))
                    }
                    .buttonStyle(.edith(.borderless))
                    Spacer()
                    Button("Clean") { confirmClean = true }
                        .font(.system(size: UIScale.pt(10.5), weight: .medium))
                        .buttonStyle(.edith(.borderless))
                        .disabled(model.selectedItemCount(categoryID: category.id) == 0)
                }
                .padding(.horizontal, UIScale.pt(6))
                .padding(.vertical, UIScale.pt(7))
            }
            if isExpanded {
                if showItemFilter {
                    SearchField(
                        placeholder: "Filter \(category.items.count) items", text: $itemFilter,
                        compact: true
                    )
                    .padding(.leading, UIScale.pt(26)).padding(.bottom, UIScale.pt(4))
                }
                ForEach(visibleItems) { item in
                    CleanerItemRow(
                        model: model, categoryID: category.id, item: item, dark: dark)
                }
                .padding(.bottom, UIScale.pt(4))
            }
            Divider().opacity(0.3)
        }
        .confirmationDialog(
            "Clean \(JunkScanner.format(model.selectedTotal(categoryID: category.id)))?",
            isPresented: $confirmClean, titleVisibility: .visible
        ) {
            Button(
                "Move \(model.selectedItemCount(categoryID: category.id)) items to Trash",
                role: .destructive
            ) {
                model.clean(categoryID: category.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items go to the Trash, so you can restore them until you empty it.")
        }
    }

    private var checkboxSymbol: String {
        switch category.selection {
        case .all: "checkmark.square.fill"
        case .some: "minus.square.fill"
        case .none: "square"
        }
    }
}

private struct CleanerFilterBar: View {
    let model: CleanerModel
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            HStack(spacing: UIScale.pt(10)) {
                caption("UNTOUCHED FOR")
                EdithSegmentedPicker(
                    "Untouched for",
                    selection: Binding(get: { model.age }, set: { model.setAge($0) }),
                    options: CleanerAge.allCases, label: \.label)
                InfoDot(
                    "Project folders and worktrees whose sources and git index have not changed for this long. Build output does not count as an edit. Global caches always show."
                )
            }
            HStack(spacing: UIScale.pt(10)) {
                caption("SORT")
                EdithSegmentedPicker(
                    "Sort",
                    selection: Binding(get: { model.filters.sort }, set: { model.setSort($0) }),
                    options: CleanerSort.allCases, label: \.label
                )
                .frame(maxWidth: UIScale.pt(160))
                Spacer(minLength: UIScale.pt(8))
                Toggle(
                    "Protect worktrees with uncommitted changes",
                    isOn: Binding(
                        get: { model.filters.protectDirty },
                        set: { model.setProtectDirty($0) })
                )
                .toggleStyle(.checkbox)
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(DashSkin.inkSoft(dark))
            }
        }
        .padding(.vertical, UIScale.pt(2))
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: UIScale.pt(10), weight: .bold)).tracking(UIScale.pt(0.6))
            .foregroundStyle(DashSkin.inkFaint(dark))
            .frame(minWidth: UIScale.pt(96), alignment: .leading)
    }
}

private struct CleanerItemRow: View {
    let model: CleanerModel
    let categoryID: String
    let item: JunkItem
    let dark: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            model.toggleItem(categoryID: categoryID, itemID: item.id)
        } label: {
            HStack(spacing: UIScale.pt(10)) {
                Image(systemName: item.selected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(item.selected ? DashSkin.accent(dark) : .secondary)
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text(item.name).font(.system(size: UIScale.pt(11))).lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .help(item.path.path)
                    if let worktree = item.worktree { worktreeLine(worktree) }
                }
                Spacer()
                if let age = CleanerAgeText.since(item.lastModified, now: Date()) {
                    Text(age)
                        .font(.system(size: UIScale.pt(10)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .help("Last edited")
                }
                Text(JunkScanner.format(item.sizeBytes))
                    .font(.system(size: UIScale.pt(10.5), design: .monospaced))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .frame(width: UIScale.pt(66), alignment: .trailing)
            }
            .padding(.leading, UIScale.pt(26)).padding(.trailing, UIScale.pt(6)).padding(
                .vertical, UIScale.pt(4)
            )
            .background(
                RoundedRectangle(cornerRadius: UIScale.pt(6))
                    .fill(hovering ? DashSkin.inkFaint(dark).opacity(0.12) : .clear)
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

    private func worktreeLine(_ worktree: WorktreeInfo) -> some View {
        HStack(spacing: UIScale.pt(5)) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: UIScale.pt(9)))
            Text(worktree.branch ?? "detached")
                .font(.system(size: UIScale.pt(10), design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
            ForEach(badges(worktree), id: \.self) { badge in
                Text(badge)
                    .font(.system(size: UIScale.pt(8.5), weight: .bold)).tracking(UIScale.pt(0.3))
                    .padding(.horizontal, UIScale.pt(5)).padding(.vertical, UIScale.pt(1))
                    .background(DashSkin.inkFaint(dark).opacity(0.15), in: Capsule())
            }
        }
        .foregroundStyle(DashSkin.inkFaint(dark))
    }

    private func badges(_ worktree: WorktreeInfo) -> [String] {
        var badges: [String] = []
        if worktree.dirty == true { badges.append("UNCOMMITTED") }
        if let unpushed = worktree.unpushed, unpushed > 0 { badges.append("\(unpushed) UNPUSHED") }
        if worktree.merged {
            badges.append("MERGED")
        } else if worktree.upstreamGone {
            badges.append("UPSTREAM GONE")
        }
        if worktree.locked { badges.append("LOCKED") }
        return badges
    }
}

private struct DriveRow: View {
    let drive: DriveInfo
    let dark: Bool

    var body: some View {
        HStack(spacing: UIScale.pt(6)) {
            Image(systemName: drive.isExternal ? "externaldrive.fill" : "internaldrive.fill")
                .font(.system(size: UIScale.pt(11))).foregroundStyle(DashSkin.inkFaint(dark))
            Text(drive.name).font(.system(size: UIScale.pt(12), weight: .medium))
            if drive.isExternal {
                Text("EXTERNAL").font(.system(size: UIScale.pt(8), weight: .bold)).tracking(
                    UIScale.pt(0.4)
                )
                .padding(.horizontal, UIScale.pt(5)).padding(.vertical, UIScale.pt(1))
                .background(DashSkin.inkFaint(dark).opacity(0.15), in: Capsule())
                .foregroundStyle(DashSkin.inkFaint(dark))
            }
            Spacer()
            Text("\(JunkScanner.format(drive.totalBytes)) capacity")
                .font(.system(size: UIScale.pt(11), design: .monospaced)).foregroundStyle(
                    DashSkin.inkFaint(dark))
        }
        .padding(UIScale.pt(10))
        .widgetBar(cornerRadius: 10, fill: DashSkin.paper2(dark))
    }
}

private struct DriveSkeleton: View {
    let dark: Bool

    var body: some View {
        SkeletonGroup {
            HStack(spacing: UIScale.pt(6)) {
                SkeletonBlock(width: 11, height: 13, corner: 3)
                SkeletonBlock(width: 120, height: 10, corner: 4)
                SkeletonBlock(width: 54, height: 14, corner: 7)
                Spacer()
                SkeletonBlock(width: 112, height: 9, corner: 4)
            }
            .padding(UIScale.pt(10))
            .widgetBar(cornerRadius: 10, fill: DashSkin.paper2(dark))
        }
    }
}

private struct DrivePickerRowSkeleton: View {
    let index: Int
    let dark: Bool

    var body: some View {
        SkeletonGroup {
            HStack(spacing: UIScale.pt(10)) {
                SkeletonBlock(width: 14, height: 14, corner: 3)
                SkeletonBlock(width: 14, height: 16, corner: 3)
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    SkeletonBlock(
                        width: index.isMultiple(of: 2) ? 118 : 156,
                        height: 10)
                    SkeletonBlock(width: 104, height: 8)
                }
                Spacer()
            }
            .padding(.horizontal, UIScale.pt(12))
            .padding(.vertical, UIScale.pt(8))
            .widgetBar(cornerRadius: 8, fill: DashSkin.paper2(dark))
        }
    }
}
