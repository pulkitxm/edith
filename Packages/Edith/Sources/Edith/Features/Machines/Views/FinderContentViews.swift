import AppKit
import EdithKit
import SwiftUI
import UniformTypeIdentifiers

enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for entry: RemoteFileEntry) -> NSImage {
        if entry.isDirectory { return cached(key: "__folder", type: .folder) }
        if entry.kind == .symlink { return cached(key: "__link", type: .symbolicLink) }
        let ext = entry.fileExtension
        guard !ext.isEmpty else { return cached(key: "__data", type: .data) }
        if let type = UTType(filenameExtension: ext) {
            return cached(key: ext, type: type)
        }
        return cached(key: "__data", type: .data)
    }

    private static func cached(key: String, type: UTType) -> NSImage {
        if let existing = cache[key] { return existing }
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }
}

enum FinderClick {
    static var currentModifiers: EventModifiers {
        var modifiers = EventModifiers()
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }
}

struct FinderIconView: View {
    let model: FinderModel
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(minimum: UIScale.pt(model.iconSize + 34)),
                                spacing: UIScale.pt(12))
                        ], spacing: UIScale.pt(14)
                    ) {
                        ForEach(model.visibleEntries) { entry in
                            FinderIconCell(model: model, entry: entry, dark: dark)
                                .id(entry.path)
                        }
                    }
                    .padding(UIScale.pt(16))
                }
                .onChange(of: model.scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                    model.scrollTarget = nil
                }
                .onAppear {
                    model.gridColumns = Self.columns(width: geometry.size.width, model: model)
                }
                .onChange(of: geometry.size.width) { _, width in
                    model.gridColumns = Self.columns(width: width, model: model)
                }
                .onChange(of: model.iconSize) { _, _ in
                    model.gridColumns = Self.columns(width: geometry.size.width, model: model)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selection = [] }
    }
}

extension FinderIconView {
    static func columns(width: CGFloat, model: FinderModel) -> Int {
        let cell = UIScale.pt(model.iconSize + 34) + UIScale.pt(12)
        let usable = max(width - UIScale.pt(32), cell)
        return max(1, Int(usable / cell))
    }
}

private struct FinderIconCell: View {
    @Bindable var model: FinderModel
    let entry: RemoteFileEntry
    let dark: Bool
    @State private var hovering = false
    @State private var dropTargeted = false
    @FocusState private var renameFocused: Bool

    private var selected: Bool { model.selection.contains(entry.path) }

    var body: some View {
        VStack(spacing: UIScale.pt(6)) {
            Image(nsImage: FileIcons.icon(for: entry))
                .resizable()
                .interpolation(.high)
                .frame(width: UIScale.pt(model.iconSize), height: UIScale.pt(model.iconSize))
            label
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, UIScale.pt(6))
        .background(
            RoundedRectangle(cornerRadius: UIScale.pt(8))
                .fill(
                    dropTargeted
                        ? DashSkin.accent(dark).opacity(0.38)
                        : (selected
                            ? DashSkin.accent(dark).opacity(0.2)
                            : (hovering ? DashSkin.inkFaint(dark).opacity(0.08) : .clear)))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.open(entry) }
        .onTapGesture(count: 1) {
            model.click(entry, modifiers: FinderClick.currentModifiers)
        }
        .onDrag {
            if !model.selection.contains(entry.path) {
                model.click(entry, modifiers: [])
            }
            return model.dragProvider(for: entry)
        }
        .onDrop(
            of: [MachineItemsPayload.typeIdentifier, UTType.fileURL.identifier],
            isTargeted: $dropTargeted
        ) { providers in
            guard entry.isDirectory else { return false }
            let option = NSEvent.modifierFlags.contains(.option)
            Task {
                await model.handleDrop(
                    providers: providers, destination: entry.path, optionHeld: option)
            }
            return true
        }
        .contextMenu { FinderRowContextMenu(model: model, entry: entry) }
    }

    @ViewBuilder
    private var label: some View {
        if model.renaming == entry.path {
            TextField("", text: $model.renameText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: UIScale.pt(11)))
                .frame(width: UIScale.pt(model.iconSize + 30))
                .focused($renameFocused)
                .task { renameFocused = true }
                .onExitCommand { model.renaming = nil }
                .onSubmit { Task { await model.commitRename() } }
        } else {
            Text(entry.name)
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(DashSkin.ink(dark))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, UIScale.pt(4))
                .background(
                    selected ? DashSkin.accent(dark).opacity(0.28) : .clear,
                    in: RoundedRectangle(cornerRadius: UIScale.pt(4)))
        }
    }
}

struct FinderListView: View {
    let model: FinderModel
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visibleEntries) { entry in
                            FinderListRow(model: model, entry: entry, dark: dark)
                                .id(entry.path)
                        }
                    }
                }
                .onChange(of: model.scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                    model.scrollTarget = nil
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.selection = [] }
        }
    }

    private var header: some View {
        HStack(spacing: UIScale.pt(10)) {
            headerButton("Name", key: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, UIScale.pt(30))
            headerButton("Date Modified", key: .modified)
                .frame(width: UIScale.pt(130), alignment: .trailing)
            headerButton("Size", key: .size)
                .frame(width: UIScale.pt(78), alignment: .trailing)
            headerButton("Kind", key: .kind)
                .frame(width: UIScale.pt(92), alignment: .trailing)
        }
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(5))
        .background(.thinMaterial)
    }

    private func headerButton(_ title: String, key: FileSortKey) -> some View {
        Button {
            if model.sortKey == key {
                model.sortAscending.toggle()
            } else {
                model.sortKey = key
                model.sortAscending = true
            }
        } label: {
            HStack(spacing: UIScale.pt(3)) {
                Text(title)
                    .font(.system(size: UIScale.pt(10), weight: .medium))
                if model.sortKey == key {
                    Image(systemName: model.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: UIScale.pt(7), weight: .bold))
                }
            }
            .foregroundStyle(
                model.sortKey == key ? DashSkin.accent(dark) : DashSkin.inkFaint(dark)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

private struct FinderListRow: View {
    @Bindable var model: FinderModel
    let entry: RemoteFileEntry
    let dark: Bool
    @State private var hovering = false
    @State private var dropTargeted = false
    @FocusState private var renameFocused: Bool

    private var selected: Bool { model.selection.contains(entry.path) }

    var body: some View {
        HStack(spacing: UIScale.pt(10)) {
            Image(nsImage: FileIcons.icon(for: entry))
                .resizable()
                .frame(width: UIScale.pt(16), height: UIScale.pt(16))
            nameLabel
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                .font(DashSkin.mono(10))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .frame(width: UIScale.pt(130), alignment: .trailing)
            Text(entry.isDirectory ? "—" : ByteFormatter.string(entry.sizeBytes))
                .font(DashSkin.mono(10))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .frame(width: UIScale.pt(78), alignment: .trailing)
            Text(entry.kindDescription)
                .font(.system(size: UIScale.pt(10.5)))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .lineLimit(1)
                .frame(width: UIScale.pt(92), alignment: .trailing)
        }
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(4))
        .background(
            dropTargeted
                ? DashSkin.accent(dark).opacity(0.34)
                : (selected
                    ? DashSkin.accent(dark).opacity(0.22)
                    : (hovering ? DashSkin.inkFaint(dark).opacity(0.07) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.open(entry) }
        .onTapGesture(count: 1) {
            model.click(entry, modifiers: FinderClick.currentModifiers)
        }
        .onDrag {
            if !model.selection.contains(entry.path) {
                model.click(entry, modifiers: [])
            }
            return model.dragProvider(for: entry)
        }
        .onDrop(
            of: [MachineItemsPayload.typeIdentifier, UTType.fileURL.identifier],
            isTargeted: $dropTargeted
        ) { providers in
            guard entry.isDirectory else { return false }
            let option = NSEvent.modifierFlags.contains(.option)
            Task {
                await model.handleDrop(
                    providers: providers, destination: entry.path, optionHeld: option)
            }
            return true
        }
        .contextMenu { FinderRowContextMenu(model: model, entry: entry) }
    }

    @ViewBuilder
    private var nameLabel: some View {
        if model.renaming == entry.path {
            TextField("", text: $model.renameText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: UIScale.pt(12)))
                .focused($renameFocused)
                .task { renameFocused = true }
                .onExitCommand { model.renaming = nil }
                .onSubmit { Task { await model.commitRename() } }
        } else {
            HStack(spacing: UIScale.pt(5)) {
                Text(entry.name)
                    .font(.system(size: UIScale.pt(12.5)))
                    .foregroundStyle(DashSkin.ink(dark))
                    .lineLimit(1)
                if let target = entry.linkTarget {
                    Text("→ \(target)")
                        .font(DashSkin.mono(9.5))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .lineLimit(1)
                }
            }
        }
    }
}

struct QuickLookOverlay: View {
    let model: FinderModel
    @Environment(\.colorScheme) private var scheme
    @State private var shown = false

    private var dark: Bool { scheme == .dark }

    private var entry: RemoteFileEntry? {
        model.visibleEntries.first { $0.path == model.quickLookPath }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            panel
                .scaleEffect(shown ? 1 : 0.88)
                .opacity(shown ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { shown = true }
            if let entry, entry.isDirectory { Task { await model.measure(entry) } }
        }
        .onChange(of: model.quickLookPath) { _, _ in
            guard let entry, entry.isDirectory else { return }
            Task { await model.measure(entry) }
        }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.16)) { shown = false }
        model.quickLookPath = nil
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            body(for: entry)
        }
        .frame(width: UIScale.pt(680), height: UIScale.pt(500))
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: UIScale.pt(16)))
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(16))
                .strokeBorder(DashSkin.line(dark).opacity(0.7))
        }
        .shadow(color: .black.opacity(0.45), radius: UIScale.pt(34), y: 14)
    }

    private var header: some View {
        HStack(spacing: UIScale.pt(10)) {
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(HoverButtonStyle())
            .help("Close (space)")
            Spacer(minLength: 0)
            Text(entry?.name ?? "")
                .font(.system(size: UIScale.pt(12.5), weight: .medium))
                .foregroundStyle(DashSkin.ink(dark))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                model.moveSelection(by: -1, extend: false)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(HoverButtonStyle())
            .help("Previous")
            Button {
                model.moveSelection(by: 1, extend: false)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(HoverButtonStyle())
            .help("Next")
            if let entry, !entry.isDirectory {
                Button("Open") { model.open(entry) }
                    .pointerCursor()
                    .font(.system(size: UIScale.pt(11), weight: .medium))
            }
        }
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(9))
    }

    @ViewBuilder
    private func body(for entry: RemoteFileEntry?) -> some View {
        if let entry, entry.isDirectory {
            folderSummary(entry)
        } else {
            FilePreviewPane(entry: entry, session: model.session)
        }
    }

    private func folderSummary(_ entry: RemoteFileEntry) -> some View {
        HStack(spacing: UIScale.pt(24)) {
            Image(nsImage: FileIcons.icon(for: entry))
                .resizable()
                .interpolation(.high)
                .frame(width: UIScale.pt(150), height: UIScale.pt(150))
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                Text(entry.name)
                    .font(DashSkin.serif(22))
                    .foregroundStyle(DashSkin.ink(dark))
                    .lineLimit(2)
                Text(model.folderSummary(for: entry))
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                if let modified = entry.modified {
                    Text(
                        "Last modified "
                            + modified.formatted(date: .abbreviated, time: .shortened)
                    )
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                }
                Button("Open Folder") { model.open(entry) }
                    .pointerCursor()
                    .padding(.top, UIScale.pt(4))
            }
            Spacer(minLength: 0)
        }
        .padding(UIScale.pt(28))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct FinderSidebar: View {
    let model: FinderModel
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(14)) {
                ForEach(model.places) { section in
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        Text(section.title.uppercased())
                            .font(.system(size: UIScale.pt(9.5), weight: .semibold))
                            .tracking(UIScale.pt(0.6))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .padding(.horizontal, UIScale.pt(10))
                            .padding(.bottom, UIScale.pt(2))
                        ForEach(section.places) { place in
                            FinderSidebarRow(model: model, place: place, dark: dark)
                        }
                    }
                }
            }
            .padding(.vertical, UIScale.pt(12))
        }
        .background(.thinMaterial)
    }
}

private struct FinderSidebarRow: View {
    let model: FinderModel
    let place: FilePlace
    let dark: Bool
    @State private var hovering = false
    @State private var targeted = false

    private var selected: Bool { model.path == place.path }

    var body: some View {
        Button {
            model.navigate(to: place.path)
        } label: {
            HStack(spacing: UIScale.pt(7)) {
                Image(systemName: place.symbol)
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(
                        selected ? DashSkin.accent(dark) : DashSkin.inkSoft(dark)
                    )
                    .frame(width: UIScale.pt(15))
                Text(place.name)
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.ink(dark))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, UIScale.pt(10))
            .padding(.vertical, UIScale.pt(5))
            .background(
                RoundedRectangle(cornerRadius: UIScale.pt(6))
                    .fill(
                        selected
                            ? DashSkin.accent(dark).opacity(0.18)
                            : (targeted
                                ? DashSkin.accent(dark).opacity(0.28)
                                : (hovering
                                    ? DashSkin.inkFaint(dark).opacity(0.08) : .clear))
                    )
                    .padding(.horizontal, UIScale.pt(6))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering = $0 }
        .onDrop(
            of: [MachineItemsPayload.typeIdentifier, UTType.fileURL.identifier],
            isTargeted: $targeted
        ) { providers in
            let option = NSEvent.modifierFlags.contains(.option)
            Task {
                await model.handleDrop(
                    providers: providers, destination: place.path, optionHeld: option)
            }
            return true
        }
    }
}

struct FinderInfoSheet: View {
    let model: FinderModel
    let entry: RemoteFileEntry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        let summary = model.infoSummary(for: entry)
        VStack(alignment: .leading, spacing: UIScale.pt(0)) {
            HStack(spacing: UIScale.pt(12)) {
                Image(nsImage: FileIcons.icon(for: entry))
                    .resizable()
                    .frame(width: UIScale.pt(52), height: UIScale.pt(52))
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text(summary.name)
                        .font(DashSkin.serif(17))
                        .foregroundStyle(DashSkin.ink(dark))
                        .lineLimit(2)
                    Text(summary.kind)
                        .font(.system(size: UIScale.pt(11.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
                Spacer(minLength: 0)
            }
            .padding(UIScale.pt(16))
            Divider()
            VStack(alignment: .leading, spacing: UIScale.pt(9)) {
                infoRow("Size", summary.size)
                infoRow("Where", (summary.path as NSString).deletingLastPathComponent)
                infoRow("Modified", summary.modified)
                infoRow("Permissions", summary.permissions)
                if let target = summary.linkTarget {
                    infoRow("Links to", target)
                }
            }
            .padding(UIScale.pt(16))
            Spacer(minLength: 0)
            Divider()
            HStack {
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(summary.path, forType: .string)
                }
                .pointerCursor()
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .pointerCursor()
            }
            .padding(UIScale.pt(14))
        }
        .frame(width: UIScale.pt(420), height: UIScale.pt(360))
        .background(DashSkin.paper(dark))
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: UIScale.pt(10)) {
            Text(label)
                .font(.system(size: UIScale.pt(11.5), weight: .medium))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .frame(width: UIScale.pt(88), alignment: .trailing)
            Text(value)
                .font(.system(size: UIScale.pt(11.5)))
                .foregroundStyle(DashSkin.ink(dark))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

struct FinderConflictSheet: View {
    let model: FinderModel
    let conflict: FinderModel.PendingConflict
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            Text(
                conflict.names.count == 1
                    ? "An item named \"\(conflict.names[0])\" already exists here."
                    : "\(conflict.names.count) items already exist here."
            )
            .font(DashSkin.serif(17))
            .foregroundStyle(DashSkin.ink(dark))
            if conflict.names.count > 1 {
                ScrollView {
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        ForEach(conflict.names, id: \.self) { name in
                            Text(name)
                                .font(DashSkin.mono(10.5))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                        }
                    }
                }
                .frame(maxHeight: UIScale.pt(120))
            }
            Text("Choose what to do with the items you are moving.")
                .font(.system(size: UIScale.pt(11.5)))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Spacer(minLength: 0)
            HStack(spacing: UIScale.pt(8)) {
                Button("Cancel") {
                    model.pendingConflict = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Skip") { resolve(.skip) }
                Button("Keep Both") { resolve(.keepBoth) }
                Button("Replace") { resolve(.replace) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(UIScale.pt(20))
        .frame(width: UIScale.pt(440), height: UIScale.pt(240))
        .background(DashSkin.paper(dark))
    }

    private func resolve(_ resolution: NameConflictResolution) {
        let resolutions = Dictionary(
            uniqueKeysWithValues: conflict.names.map { ($0, resolution) })
        model.pendingConflict = nil
        dismiss()
        Task {
            await model.commit(
                intent: conflict.intent, destination: conflict.destination,
                resolutions: resolutions)
        }
    }
}
