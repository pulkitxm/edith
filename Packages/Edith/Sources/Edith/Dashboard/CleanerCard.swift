import AppKit
import EdithKit
import SwiftUI

final class CancelToken: @unchecked Sendable {
    var cancelled = false
}

@MainActor
final class CleanerModel: ObservableObject {
    static let shared = CleanerModel()
    private static let confirmedExternalPathsKey = "cleanerConfirmedExternalPaths"

    @Published private(set) var categories: [JunkCategory] = []
    @Published private(set) var scanning = false
    @Published private(set) var scanned = false
    @Published private(set) var logs: [String] = []
    @Published var logsExpanded = false
    @Published private(set) var lastReclaimed: Int64 = 0
    @Published private(set) var drives: [DriveInfo] = []
    @Published private(set) var driveOptions: [DriveInfo] = []
    @Published private(set) var customFolders: [String] = []
    @Published var search = ""
    @Published var expanded: Set<String> = []
    @Published private var driveSelection: Set<String>?
    private var scanToken: CancelToken?

    init() {
        let confirmed = Set(
            SharedDefaults.store.array(forKey: Self.confirmedExternalPathsKey) as? [String] ?? [])
        if let raw = SharedDefaults.store.array(forKey: "cleanerSelectedDrives") as? [String] {
            let kept = raw.filter { Self.pathIsAllowed($0, confirmed: confirmed) }
            driveSelection = Set(kept)
        }
        if let raw = SharedDefaults.store.array(forKey: "cleanerCustomFolders") as? [String] {
            let kept = raw.filter { Self.pathIsAllowed($0, confirmed: confirmed) }
            customFolders = kept
        }
    }

    func addCustomFolder(_ path: String) {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !customFolders.contains(standardizedPath) else { return }
        confirmExternalPathIfNeeded(standardizedPath)
        customFolders.append(standardizedPath)
        SharedDefaults.store.set(customFolders, forKey: "cleanerCustomFolders")
        var selection = driveSelection ?? ["/"]
        selection.insert(standardizedPath)
        driveSelection = selection
        SharedDefaults.store.set(Array(selection), forKey: "cleanerSelectedDrives")
    }

    func removeCustomFolder(_ path: String) {
        customFolders.removeAll { $0 == path }
        SharedDefaults.store.set(customFolders, forKey: "cleanerCustomFolders")
        driveSelection?.remove(path)
        if driveSelection != nil {
            SharedDefaults.store.set(Array(driveSelection ?? []), forKey: "cleanerSelectedDrives")
        }
        removeExternalConfirmation(path)
    }

    var reclaimableTotal: Int64 { categories.reduce(0) { $0 + $1.sizeBytes } }
    var selectedTotal: Int64 { categories.reduce(0) { $0 + $1.selectedBytes } }

    var totalItemCount: Int { categories.reduce(0) { $0 + $1.items.count } }
    var selectedItemCount: Int {
        categories.reduce(0) { $0 + $1.items.filter(\.selected).count }
    }

    var overallSelection: JunkSelection {
        let total = totalItemCount
        guard total > 0 else { return .none }
        let selected = selectedItemCount
        if selected == 0 { return .none }
        if selected == total { return .all }
        return .some
    }

    var filteredCategories: [JunkCategory] {
        guard !search.isEmpty else { return categories }
        let query = search.lowercased()
        return categories.compactMap { category in
            if category.name.lowercased().contains(query) { return category }
            let items = category.items.filter { $0.name.lowercased().contains(query) }
            guard !items.isEmpty else { return nil }
            var trimmed = category
            trimmed.items = items
            return trimmed
        }
    }

    func loadDriveOptions() {
        Task {
            let all = await Task.detached { JunkScanner.drives() }.value
            driveOptions = all
        }
    }

    func isDriveSelected(_ id: String) -> Bool {
        driveSelection?.contains(id) ?? (id == "/")
    }

    func toggleDrive(_ id: String) {
        var selection = driveSelection ?? ["/"]
        if selection.contains(id) {
            selection.remove(id)
            if !customFolders.contains(id) { removeExternalConfirmation(id) }
        } else {
            confirmExternalPathIfNeeded(id)
            selection.insert(id)
        }
        driveSelection = selection
        SharedDefaults.store.set(Array(selection), forKey: "cleanerSelectedDrives")
    }

    private static func pathIsAllowed(_ path: String, confirmed: Set<String>) -> Bool {
        RestoredPathValidation.verdict(for: path) == .keep
            || confirmed.contains(URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    private func confirmExternalPathIfNeeded(_ path: String) {
        guard RestoredPathValidation.verdict(for: path) == .drop else { return }
        var confirmed = Set(
            SharedDefaults.store.array(forKey: Self.confirmedExternalPathsKey) as? [String] ?? [])
        confirmed.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
        SharedDefaults.store.set(Array(confirmed), forKey: Self.confirmedExternalPathsKey)
    }

    private func removeExternalConfirmation(_ path: String) {
        var confirmed = Set(
            SharedDefaults.store.array(forKey: Self.confirmedExternalPathsKey) as? [String] ?? [])
        confirmed.remove(URL(fileURLWithPath: path).standardizedFileURL.path)
        SharedDefaults.store.set(Array(confirmed), forKey: Self.confirmedExternalPathsKey)
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        scanned = false
        logs = []
        logsExpanded = true
        categories = []
        drives = []
        let token = CancelToken()
        scanToken = token
        Task {
            let all = await Task.detached { JunkScanner.drives() }.value
            driveOptions = all
            drives = JunkScanner.drivesForScanning(all, selectedDriveIDs: driveSelection)
            let choices = overrides
            let categoryChoices = categoryDefaults
            let home = FileManager.default.homeDirectoryForCurrentUser
            for entry in JunkCatalog.entries {
                if token.cancelled { break }
                log("Scanning \(entry.name)…")
                let found = await Task.detached {
                    JunkScanner.scanCategory(entry, home: home, isCancelled: { token.cancelled })
                }.value
                if token.cancelled { break }
                if let category = found {
                    categories.append(
                        Self.applyChoices(category, items: choices, categories: categoryChoices))
                    log("  \(category.name) · \(JunkScanner.format(category.sizeBytes))")
                }
            }
            var roots = drives.map { $0.id == "/" ? home : URL(fileURLWithPath: $0.id) }
            roots += customFolders.filter { isDriveSelected($0) }.map { URL(fileURLWithPath: $0) }
            if !roots.isEmpty, !token.cancelled {
                let projects = await Task.detached {
                    JunkScanner.scanProjectJunk(roots: roots, isCancelled: { token.cancelled }) {
                        line in
                        Task { @MainActor in CleanerModel.shared.log(line) }
                    }
                }.value
                if !token.cancelled {
                    for category in projects {
                        categories.append(
                            Self.applyChoices(
                                category, items: choices, categories: categoryChoices))
                        log(
                            "  \(category.name) · \(JunkScanner.format(category.sizeBytes))")
                    }
                }
            }
            if token.cancelled {
                log("Cancelled.")
                scanned = !categories.isEmpty
            } else {
                log("Done · \(JunkScanner.format(reclaimableTotal)) reclaimable.")
                scanned = true
            }
            scanning = false
            try? await Task.sleep(for: .seconds(0.9))
            if !token.cancelled {
                withAnimation(.easeInOut(duration: 0.35)) { logsExpanded = false }
            }
        }
    }

    private func log(_ line: String) {
        logs.append(line)
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
    }

    func cancelScan() {
        guard scanning else { return }
        scanToken?.cancelled = true
    }

    private static func applyChoices(
        _ category: JunkCategory, items itemChoices: [String: Bool],
        categories categoryChoices: [String: Bool]
    ) -> JunkCategory {
        var updated = category
        let categoryDefault = categoryChoices[category.id]
        updated.items = category.items.map { item in
            var copy = item
            if let choice = itemChoices[item.id] {
                copy.selected = choice
            } else if let categoryDefault {
                copy.selected = categoryDefault
            }
            return copy
        }
        return updated
    }

    func toggleAll() {
        let selectAll = overallSelection != .all
        var itemChoices = overrides
        var categoryChoices = categoryDefaults
        for index in categories.indices {
            categoryChoices[categories[index].id] = selectAll
            for item in categories[index].items { itemChoices[item.id] = nil }
            for item in categories[index].items.indices {
                categories[index].items[item].selected = selectAll
            }
        }
        overrides = itemChoices
        categoryDefaults = categoryChoices
    }

    func toggleCategory(_ id: String) {
        guard let index = categories.firstIndex(where: { $0.id == id }) else { return }
        let selectAll = categories[index].selection != .all
        var itemChoices = overrides
        for item in categories[index].items {
            itemChoices[item.id] = nil
        }
        overrides = itemChoices
        var categoryChoices = categoryDefaults
        categoryChoices[id] = selectAll
        categoryDefaults = categoryChoices
        for item in categories[index].items.indices {
            categories[index].items[item].selected = selectAll
        }
    }

    func toggleItem(categoryID: String, itemID: String) {
        guard let categoryIndex = categories.firstIndex(where: { $0.id == categoryID }),
            let itemIndex = categories[categoryIndex].items.firstIndex(where: { $0.id == itemID })
        else { return }
        categories[categoryIndex].items[itemIndex].selected.toggle()
        var choices = overrides
        choices[itemID] = categories[categoryIndex].items[itemIndex].selected
        overrides = choices
    }

    func toggleExpand(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    func clean() {
        let items = categories.flatMap { $0.items.filter(\.selected) }
        guard !items.isEmpty else { return }
        scanning = true
        Task {
            let reclaimed = await Task.detached { JunkScanner.clean(items) }.value
            lastReclaimed = reclaimed
            scanning = false
            scan()
        }
    }

    private var overrides: [String: Bool] {
        get {
            (SharedDefaults.store.dictionary(forKey: "cleanerSelectionOverrides") ?? [:])
                .compactMapValues { $0 as? Bool }
        }
        set { SharedDefaults.store.set(newValue, forKey: "cleanerSelectionOverrides") }
    }

    private var categoryDefaults: [String: Bool] {
        get {
            (SharedDefaults.store.dictionary(forKey: "cleanerCategoryDefaults") ?? [:])
                .compactMapValues { $0 as? Bool }
        }
        set { SharedDefaults.store.set(newValue, forKey: "cleanerCategoryDefaults") }
    }
}

struct CleanerCard: View {
    let dark: Bool
    @ObservedObject private var model = CleanerModel.shared
    @State private var showDrivePicker = false
    @State private var pickerScans = false
    @State private var confirmClean = false

    var body: some View {
        SkinCard(title: "Reclaim developer space", dark: dark) {
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
                            selectAllRow
                            ForEach(model.filteredCategories) { category in
                                CleanerCategoryRow(model: model, category: category, dark: dark)
                            }
                            footer
                        } else {
                            Text("Nothing to clean. You're already tidy.")
                                .font(.system(size: UIScale.pt(12))).foregroundStyle(
                                    DashSkin.inkFaint(dark))
                        }
                    }
                }
                if model.lastReclaimed > 0 {
                    Text("Reclaimed \(JunkScanner.format(model.lastReclaimed)) last clean.")
                        .font(.system(size: UIScale.pt(11))).foregroundStyle(DashSkin.sage)
                }
            }
        }
        .sheet(isPresented: $showDrivePicker) {
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
            Text("Items go to the Trash, so you can restore them until you empty it.")
        }
    }

    private var intro: some View {
        HStack {
            Text("Scan build caches, package managers, Claude Code logs, and your drives.")
                .font(.system(size: UIScale.pt(12))).foregroundStyle(DashSkin.inkFaint(dark))
            Spacer()
            Button("Scan") { openPicker(scan: true) }.pointerCursor()
        }
    }

    private var header: some View {
        HStack(spacing: UIScale.pt(8)) {
            if model.scanning {
                ProgressView().controlSize(.small)
                Text("Scanning…").font(.system(size: UIScale.pt(12))).foregroundStyle(
                    DashSkin.inkSoft(dark))
                Button("Cancel") { model.cancelScan() }
                    .font(.system(size: UIScale.pt(11), weight: .medium)).buttonStyle(.plain)
                    .pointerCursor()
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
                .buttonStyle(.plain).pointerCursor()
            }
            Spacer()
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
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
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
                    .font(.system(size: UIScale.pt(11), weight: .medium)).buttonStyle(.plain)
                    .pointerCursor()
                    .foregroundStyle(DashSkin.accent(dark)).disabled(model.scanning)
                InfoDot("Cleaning moves items to the Trash, so it stays reversible.")
                Button("Choose drives…") { openPicker(scan: false) }
                    .font(.system(size: UIScale.pt(11))).buttonStyle(.plain).pointerCursor()
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
            .buttonStyle(.plain).pointerCursor()
            Text("Select all").font(.system(size: UIScale.pt(12), weight: .medium))
            Spacer()
            Text("\(model.selectedItemCount) of \(model.totalItemCount) selected")
                .font(.system(size: UIScale.pt(10.5))).foregroundStyle(DashSkin.inkFaint(dark))
        }
        .padding(.vertical, UIScale.pt(4))
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
        .buttonStyle(.borderedProminent)
        .tint(DashSkin.accent(dark))
        .controlSize(.large)
        .disabled(model.scanning || model.selectedTotal == 0)
        .pointerCursor()
        .padding(.top, UIScale.pt(2))
    }

    private func openPicker(scan: Bool) {
        pickerScans = scan
        model.loadDriveOptions()
        showDrivePicker = true
    }
}

private struct DrivePickerSheet: View {
    @ObservedObject var model: CleanerModel
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
                "Selected drives and folders are searched for project junk like node_modules and virtualenvs. System caches always come from your home folder."
            )
            .font(.system(size: UIScale.pt(11.5))).foregroundStyle(DashSkin.inkFaint(dark))
            .padding(.horizontal, UIScale.pt(20)).padding(.top, UIScale.pt(4))

            ScrollView {
                VStack(spacing: UIScale.pt(6)) {
                    if model.driveOptions.isEmpty {
                        ProgressView().controlSize(.small).padding(.vertical, UIScale.pt(20))
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
                            .background(
                                DashSkin.paper2(dark),
                                in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
                        }
                        .buttonStyle(.plain).pointerCursor()
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
                    .buttonStyle(.plain).pointerCursor()
                }
                .padding(UIScale.pt(20))
            }
            .frame(maxHeight: UIScale.pt(280))

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.pointerCursor()
                Button(confirmTitle) {
                    dismiss()
                    onConfirm()
                }
                .keyboardShortcut(.defaultAction).pointerCursor()
            }
            .padding(.horizontal, UIScale.pt(20)).padding(.vertical, UIScale.pt(14))
        }
        .frame(width: UIScale.pt(420))
        .background(DashSkin.paper(dark))
        .onAppear { model.loadDriveOptions() }
    }

    private func folderRow(_ folder: String) -> some View {
        HStack(spacing: UIScale.pt(10)) {
            Button {
                model.toggleDrive(folder)
            } label: {
                Image(
                    systemName: model.isDriveSelected(folder)
                        ? "checkmark.square.fill" : "square"
                )
                .foregroundStyle(model.isDriveSelected(folder) ? DashSkin.accent(dark) : .secondary)
            }
            .buttonStyle(.plain).pointerCursor()
            Image(systemName: "folder.fill")
                .font(.system(size: UIScale.pt(12))).foregroundStyle(DashSkin.inkFaint(dark))
            VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                Text((folder as NSString).lastPathComponent)
                    .font(.system(size: UIScale.pt(13), weight: .medium))
                Text((folder as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: UIScale.pt(10.5), design: .monospaced))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button {
                model.removeCustomFolder(folder)
            } label: {
                Image(systemName: "trash").font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).pointerCursor().help("Remove this folder")
        }
        .padding(.horizontal, UIScale.pt(12)).padding(.vertical, UIScale.pt(8))
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
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
    @ObservedObject var model: CleanerModel
    let category: JunkCategory
    let dark: Bool
    @State private var itemFilter = ""
    @State private var headerHover = false

    private var isExpanded: Bool { model.expanded.contains(category.id) }

    private var showItemFilter: Bool { category.items.count > 10 }

    private var visibleItems: [JunkItem] {
        guard !itemFilter.isEmpty else { return category.items }
        let query = itemFilter.lowercased()
        return category.items.filter { $0.name.lowercased().contains(query) }
    }

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            HStack(spacing: UIScale.pt(10)) {
                Button {
                    model.toggleCategory(category.id)
                } label: {
                    Image(systemName: checkboxSymbol)
                        .foregroundStyle(
                            category.selection == .none ? .secondary : DashSkin.accent(dark))
                }
                .buttonStyle(.plain).pointerCursor()
                HStack(spacing: UIScale.pt(8)) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: UIScale.pt(9))).foregroundStyle(DashSkin.inkFaint(dark))
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
                }
                .contentShape(Rectangle())
                .onTapGesture { model.toggleExpand(category.id) }
                .pointerCursor()
            }
            .padding(.horizontal, UIScale.pt(6)).padding(.vertical, UIScale.pt(7))
            .background(
                RoundedRectangle(cornerRadius: UIScale.pt(7))
                    .fill(headerHover ? DashSkin.inkFaint(dark).opacity(0.1) : .clear)
            )
            .onHover { headerHover = $0 }
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
    }

    private var checkboxSymbol: String {
        switch category.selection {
        case .all: "checkmark.square.fill"
        case .some: "minus.square.fill"
        case .none: "square"
        }
    }
}

private struct CleanerItemRow: View {
    @ObservedObject var model: CleanerModel
    let categoryID: String
    let item: JunkItem
    let dark: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: UIScale.pt(10)) {
            Image(systemName: item.selected ? "checkmark.square.fill" : "square")
                .foregroundStyle(item.selected ? DashSkin.accent(dark) : .secondary)
            Text(item.name).font(.system(size: UIScale.pt(11))).lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(DashSkin.inkSoft(dark))
                .help(item.path.path)
            Spacer()
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
        .onHover { hovering = $0 }
        .onTapGesture { model.toggleItem(categoryID: categoryID, itemID: item.id) }
        .pointerCursor()
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
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
    }
}

private struct DriveSkeleton: View {
    let dark: Bool
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            RoundedRectangle(cornerRadius: UIScale.pt(4)).frame(
                width: UIScale.pt(120), height: UIScale.pt(10))
            RoundedRectangle(cornerRadius: UIScale.pt(3)).frame(height: UIScale.pt(5))
        }
        .foregroundStyle(DashSkin.inkFaint(dark).opacity(pulse ? 0.25 : 0.1))
        .padding(UIScale.pt(10))
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
