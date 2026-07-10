import EdithKit
import SwiftUI

@MainActor
final class CleanerModel: ObservableObject {
    static let shared = CleanerModel()

    @Published private(set) var categories: [JunkCategory] = []
    @Published private(set) var scanning = false
    @Published private(set) var scanned = false
    @Published private(set) var logs: [String] = []
    @Published var logsExpanded = false
    @Published private(set) var lastReclaimed: Int64 = 0
    @Published private(set) var drives: [DriveInfo] = []
    @Published private(set) var driveOptions: [DriveInfo] = []
    @Published var search = ""
    @Published var expanded: Set<String> = []
    @Published private var driveSelection: Set<String>?

    init() {
        if let raw = SharedDefaults.store.array(forKey: "cleanerSelectedDrives") as? [String] {
            driveSelection = Set(raw)
        }
    }

    var reclaimableTotal: Int64 { categories.reduce(0) { $0 + $1.sizeBytes } }
    var selectedTotal: Int64 { categories.reduce(0) { $0 + $1.selectedBytes } }

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
        driveSelection?.contains(id) ?? true
    }

    func toggleDrive(_ id: String) {
        var selection = driveSelection ?? Set(driveOptions.map(\.id))
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        driveSelection = selection
        SharedDefaults.store.set(Array(selection), forKey: "cleanerSelectedDrives")
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        scanned = false
        logs = []
        logsExpanded = true
        categories = []
        drives = []
        Task {
            let all = await Task.detached { JunkScanner.drives() }.value
            driveOptions = all
            drives = all.filter { isDriveSelected($0.id) }
            let choices = overrides
            let categoryChoices = categoryDefaults
            let home = FileManager.default.homeDirectoryForCurrentUser
            for entry in JunkCatalog.entries {
                logs.append("Scanning \(entry.name)…")
                let found = await Task.detached { JunkScanner.scanCategory(entry, home: home) }
                    .value
                if let category = found {
                    categories.append(
                        Self.applyChoices(category, items: choices, categories: categoryChoices))
                    logs.append("  \(category.name) · \(JunkScanner.format(category.sizeBytes))")
                }
            }
            let roots = drives.map { $0.id == "/" ? home : URL(fileURLWithPath: $0.id) }
            if !roots.isEmpty {
                let projects = await Task.detached {
                    JunkScanner.scanProjectJunk(roots: roots) { line in
                        Task { @MainActor in CleanerModel.shared.logs.append(line) }
                    }
                }.value
                for category in projects {
                    categories.append(
                        Self.applyChoices(category, items: choices, categories: categoryChoices))
                    logs.append("  \(category.name) · \(JunkScanner.format(category.sizeBytes))")
                }
            }
            logs.append("Done · \(JunkScanner.format(reclaimableTotal)) reclaimable.")
            scanning = false
            scanned = true
            try? await Task.sleep(for: .seconds(0.9))
            withAnimation(.easeInOut(duration: 0.35)) { logsExpanded = false }
        }
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

    var body: some View {
        SkinCard(title: "Reclaim developer space", dark: dark) {
            VStack(alignment: .leading, spacing: 12) {
                if !model.scanned && !model.scanning {
                    intro
                } else {
                    header
                    if model.logsExpanded { logView }
                    if model.scanned {
                        drivesView
                        if !model.categories.isEmpty {
                            searchBar
                            ForEach(model.filteredCategories) { category in
                                CleanerCategoryRow(model: model, category: category, dark: dark)
                            }
                            footer
                        } else {
                            Text("Nothing to clean. You're already tidy.")
                                .font(.system(size: 12)).foregroundStyle(DashSkin.inkFaint(dark))
                        }
                    }
                }
                if model.lastReclaimed > 0 {
                    Text("Reclaimed \(JunkScanner.format(model.lastReclaimed)) last clean.")
                        .font(.system(size: 11)).foregroundStyle(DashSkin.sage)
                }
            }
        }
        .sheet(isPresented: $showDrivePicker) {
            DrivePickerSheet(model: model, dark: dark) { model.scan() }
        }
    }

    private var intro: some View {
        HStack {
            Text("Scan build caches, package managers, Claude Code logs, and your drives.")
                .font(.system(size: 12)).foregroundStyle(DashSkin.inkFaint(dark))
            Spacer()
            Button("Scan") { openPicker() }.pointerCursor()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if model.scanning {
                ProgressView().controlSize(.small)
                Text("Scanning…").font(.system(size: 12)).foregroundStyle(DashSkin.inkSoft(dark))
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) { model.logsExpanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "terminal")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Logs")
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: model.logsExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(DashSkin.paper2(dark), in: Capsule())
                }
                .buttonStyle(.plain).pointerCursor()
            }
            Spacer()
        }
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(model.logs.suffix(8).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: 10))
        .clipped()
        .transition(.opacity)
    }

    private var drivesView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("DRIVES").font(.system(size: 10, weight: .bold)).tracking(0.6)
                    .foregroundStyle(DashSkin.inkFaint(dark))
                Spacer()
                Button("Choose…") { openPicker() }
                    .font(.system(size: 10.5)).buttonStyle(.plain).pointerCursor()
                    .foregroundStyle(DashSkin.accent(dark))
            }
            if model.drives.isEmpty {
                if model.scanning {
                    ForEach(0..<2, id: \.self) { _ in DriveSkeleton(dark: dark) }
                } else {
                    Text("No drives selected.")
                        .font(.system(size: 11)).foregroundStyle(DashSkin.inkFaint(dark))
                }
            } else {
                ForEach(model.drives) { drive in DriveRow(drive: drive, dark: dark) }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11))
                .foregroundStyle(DashSkin.inkFaint(dark))
            TextField("Filter", text: $model.search)
                .textFieldStyle(.plain).font(.system(size: 12))
            if !model.search.isEmpty {
                Button {
                    model.search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 10) {
                Button("Rescan") { openPicker() }.disabled(model.scanning).pointerCursor()
                Text("Moves to the Trash, reversible.")
                    .font(.system(size: 10.5)).foregroundStyle(DashSkin.inkFaint(dark))
            }
            Spacer()
            Button(role: .destructive) {
                model.clean()
            } label: {
                Text("Clean \(JunkScanner.format(model.selectedTotal))")
            }
            .disabled(model.scanning || model.selectedTotal == 0).pointerCursor()
        }
    }

    private func openPicker() {
        model.loadDriveOptions()
        showDrivePicker = true
    }
}

private struct DrivePickerSheet: View {
    @ObservedObject var model: CleanerModel
    let dark: Bool
    let onScan: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Choose drives to include")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 20).padding(.top, 20)
            Text(
                "Selected drives are searched for project junk like node_modules and virtualenvs. System caches always come from your home folder."
            )
            .font(.system(size: 11.5)).foregroundStyle(DashSkin.inkFaint(dark))
            .padding(.horizontal, 20).padding(.top, 4)

            ScrollView {
                VStack(spacing: 6) {
                    if model.driveOptions.isEmpty {
                        ProgressView().controlSize(.small).padding(.vertical, 20)
                    }
                    ForEach(model.driveOptions) { drive in
                        Button {
                            model.toggleDrive(drive.id)
                        } label: {
                            HStack(spacing: 10) {
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
                                .font(.system(size: 12)).foregroundStyle(DashSkin.inkFaint(dark))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(drive.name).font(.system(size: 13, weight: .medium))
                                    Text(
                                        "\(JunkScanner.format(drive.usedBytes)) of \(JunkScanner.format(drive.totalBytes))"
                                    )
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(DashSkin.inkFaint(dark))
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(
                                DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain).pointerCursor()
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: 280)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.pointerCursor()
                Button("Scan") {
                    dismiss()
                    onScan()
                }
                .keyboardShortcut(.defaultAction).pointerCursor()
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 420)
        .background(DashSkin.paper(dark))
        .onAppear { model.loadDriveOptions() }
    }
}

private struct CleanerCategoryRow: View {
    @ObservedObject var model: CleanerModel
    let category: JunkCategory
    let dark: Bool

    private var isExpanded: Bool { model.expanded.contains(category.id) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    model.toggleCategory(category.id)
                } label: {
                    Image(systemName: checkboxSymbol)
                        .foregroundStyle(
                            category.selection == .none ? .secondary : DashSkin.accent(dark))
                }
                .buttonStyle(.plain).pointerCursor()
                Button {
                    model.toggleExpand(category.id)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9)).foregroundStyle(DashSkin.inkFaint(dark))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(category.name).font(.system(size: 13, weight: .medium))
                            Text(category.detail).font(.system(size: 10.5))
                                .foregroundStyle(DashSkin.inkFaint(dark)).lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain).pointerCursor()
                Spacer()
                Text("\(category.items.count) items")
                    .font(.system(size: 10)).foregroundStyle(DashSkin.inkFaint(dark))
                Text(JunkScanner.format(category.sizeBytes))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .frame(width: 72, alignment: .trailing)
            }
            .padding(.vertical, 7)
            if isExpanded {
                ForEach(category.items) { item in
                    HStack(spacing: 10) {
                        Button {
                            model.toggleItem(categoryID: category.id, itemID: item.id)
                        } label: {
                            Image(systemName: item.selected ? "checkmark.square.fill" : "square")
                                .foregroundStyle(item.selected ? DashSkin.accent(dark) : .secondary)
                        }
                        .buttonStyle(.plain).pointerCursor()
                        Text(item.name).font(.system(size: 11)).lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(DashSkin.inkSoft(dark))
                            .help(item.path.path)
                        Spacer()
                        Text(JunkScanner.format(item.sizeBytes))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .frame(width: 66, alignment: .trailing)
                    }
                    .padding(.leading, 26).padding(.vertical, 3)
                }
                .padding(.bottom, 4)
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

private struct DriveRow: View {
    let drive: DriveInfo
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: drive.isExternal ? "externaldrive.fill" : "internaldrive.fill")
                    .font(.system(size: 11)).foregroundStyle(DashSkin.inkFaint(dark))
                Text(drive.name).font(.system(size: 12, weight: .medium))
                if drive.isExternal {
                    Text("EXTERNAL").font(.system(size: 8, weight: .bold)).tracking(0.4)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(DashSkin.inkFaint(dark).opacity(0.15), in: Capsule())
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
                Spacer()
                Text(
                    "\(JunkScanner.format(drive.usedBytes)) of \(JunkScanner.format(drive.totalBytes))"
                )
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(
                    DashSkin.inkFaint(dark))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.1))
                    Capsule().fill(barColor)
                        .frame(width: max(3, geo.size.width * drive.usedFraction))
                }
            }
            .frame(height: 5)
        }
        .padding(10)
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: 10))
    }

    private var barColor: Color {
        drive.usedFraction > 0.9
            ? DashPalette.color("#FF3B30") : DashSkin.accent(dark)
    }
}

private struct DriveSkeleton: View {
    let dark: Bool
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 4).frame(width: 120, height: 10)
            RoundedRectangle(cornerRadius: 3).frame(height: 5)
        }
        .foregroundStyle(DashSkin.inkFaint(dark).opacity(pulse ? 0.25 : 0.1))
        .padding(10)
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: 10))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
