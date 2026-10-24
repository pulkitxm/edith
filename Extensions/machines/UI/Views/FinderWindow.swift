import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import UniformTypeIdentifiers

struct FinderPane: View {
    let model: FinderModel
    var allowsConnections = true
    var autoFocus = true
    var onFocus: (() -> Void)?
    @Environment(\.machineConnectionsEnabled) private var connectionsEnabled

    private var connectionsAllowed: Bool { allowsConnections && connectionsEnabled }

    var body: some View {
        FinderBody(
            model: model, allowsConnections: allowsConnections, autoFocus: autoFocus,
            onFocus: onFocus
        )
        .onAppear {
            if connectionsAllowed { FinderUndoBridge.register(model) }
        }
        .onDisappear {
            if connectionsAllowed { FinderUndoBridge.forget(model) }
        }
    }
}

struct FinderWindowView: View {
    @State private var model: FinderModel

    init(session: MachineSession, path: String? = nil) {
        _model = State(wrappedValue: FinderModel(session: session, path: path))
    }

    var body: some View {
        FinderBody(model: model)
            .machineActivity(model.session)
    }
}

struct FinderBody: View {
    @Environment(\.machineViewPresented) private var presented
    @Bindable var model: FinderModel
    var allowsConnections = true
    var autoFocus = true
    var onFocus: (() -> Void)?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.machineConnectionsEnabled) private var connectionsEnabled
    @State private var confirmDelete = false
    @State private var width = 0.0
    @FocusState private var searchFocused: Bool

    private var dark: Bool { scheme == .dark }
    private var connectionsAllowed: Bool { allowsConnections && connectionsEnabled }
    private var layout: FinderLayout {
        FinderLayout(width: width, sidebarRequested: model.showSidebar)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                if layout.showsSidebar {
                    FinderSidebar(model: model)
                        .frame(width: UIScale.pt(FinderLayout.sidebarWidth))
                    Divider()
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            pathBar
            Divider().opacity(0.5)
            statusBar
        }
        .background(DashSkin.paper(dark))
        .onGeometryChange(for: Double.self) {
            $0.size.width
        } action: {
            width = $0
        }
        .task(id: presented) {
            guard connectionsAllowed, presented else {
                model.stopLoading()
                return
            }
            model.connectIfNeeded()
            await model.waitForConnection()
            await model.loadPlaces()
            await model.load()
        }
        .onChange(of: model.session.state.isConnected) { _, connected in
            if connectionsAllowed, presented, connected { model.refresh() }
        }
        .onDisappear { model.stopLoading() }
        .overlay {
            if model.quickLookPath != nil {
                QuickLookOverlay(model: model)
            }
        }
        .overlay(alignment: .topLeading) {
            FinderKeyCatcher(
                isEditing: model.renaming != nil, focusRequests: model.focusRequests,
                autoFocus: autoFocus, onFocus: onFocus,
                onHistory: { direction in
                    switch direction {
                    case .back:
                        guard model.canGoBack else { return false }
                        model.goBack()
                    case .forward:
                        guard model.canGoForward else { return false }
                        model.goForward()
                    }
                    return true
                }
            ) { key in
                handle(key)
            }
            .frame(width: 1, height: 1)
            .opacity(0.01)
        }
        .edithSheet(item: $model.infoTarget) { entry in
            FinderInfoSheet(model: model, entry: entry)
        }
        .edithSheet(item: $model.pendingConflict) { conflict in
            FinderConflictSheet(model: model, conflict: conflict)
        }
        .confirmationDialog(
            "Delete \(model.selection.count) item\(model.selection.count == 1 ? "" : "s")?",
            isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Delete Immediately", role: .destructive) {
                Task { await model.trashSelection(permanently: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func handle(_ key: FinderKey) -> Bool {
        switch key {
        case .rename:
            guard !model.selection.isEmpty else { return false }
            model.renameSelection()
        case .openSelection: model.openSelection()
        case .quickLook: model.toggleQuickLook()
        case let .move(direction, extend): model.moveSelection(direction, extend: extend)
        case .enclosingFolder: model.goUp()
        case .back: model.goBack()
        case .forward: model.goForward()
        case .selectAll: model.selectAll()
        case .trash: Task { await model.trashSelection(permanently: false) }
        case .deleteImmediately: confirmDelete = !model.selection.isEmpty
        case .newFolder: Task { await model.newFolder() }
        case .copy: model.copySelection(operation: .copy)
        case .cut: model.copySelection(operation: .move)
        case .paste: Task { await model.paste() }
        case .copyPath: model.copyPaths()
        case .info: model.showInfo()
        case .refresh: model.refresh()
        case .toggleHidden: model.toggleHidden()
        case .duplicate: Task { await model.duplicateSelection() }
        case .undo: Task { await model.undoLastOperation() }
        case .redo: return false
        case .invertSelection: model.invertSelection()
        case .toggleSidebar: model.showSidebar.toggle()
        case .iconView: model.setViewMode(.icon)
        case .listView: model.setViewMode(.list)
        case .focusSearch: searchFocused = true
        case .cancel:
            if model.quickLookPath != nil {
                model.quickLookPath = nil
            } else if model.renaming != nil {
                model.renaming = nil
            } else if model.canCancelTransfer {
                model.cancelTransfer()
            } else {
                model.selection = []
            }
        case let .type(characters): model.typeSelect(characters)
        }
        return true
    }

    private var toolbar: some View {
        HStack(spacing: UIScale.pt(8)) {
            if layout.fitsSidebar {
                Button {
                    model.showSidebar.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.edith(.toolbar))
                .help("Hide or show the sidebar (⌃⌘S)")
            }

            HStack(spacing: UIScale.pt(2)) {
                Button {
                    model.goBack()
                    model.requestKeyFocus()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!model.canGoBack)
                .help("Back (⌘[)")
                Button {
                    model.goForward()
                    model.requestKeyFocus()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!model.canGoForward)
                .help("Forward (⌘])")
                Button {
                    model.goUp()
                    model.requestKeyFocus()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(!model.canGoUp)
                .help("Enclosing folder (⌘↑)")
                Button {
                    model.goHome()
                    model.requestKeyFocus()
                } label: {
                    Image(systemName: "house")
                }
                .help("Home folder")
            }
            .buttonStyle(.edith(.toolbar))

            if !layout.compactToolbar {
                EdithSegmentedPicker(
                    "", selection: viewModeBinding, options: FileViewMode.allCases,
                    label: { $0.title }
                )
                .labelsHidden()
                .frame(width: UIScale.pt(90))
                .help("View as icons (⌘1) or list (⌘2)")

                Menu {
                    sortItems
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Sort")
            }

            Spacer(minLength: UIScale.pt(4))

            SearchField(
                placeholder: layout.compactToolbar ? "Search" : "Search this folder",
                text: $model.searchQuery, focus: $searchFocused
            )
            .frame(minWidth: UIScale.pt(70), maxWidth: UIScale.pt(200))
            .focused($searchFocused)
            .onChange(of: model.searchQuery) { _, _ in
                model.searchQueryChanged()
            }

            Menu {
                if layout.compactToolbar {
                    Picker("View", selection: viewModeBinding) {
                        ForEach(FileViewMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Menu("Sort By") { sortItems }
                    Divider()
                }
                Button("New Folder") { Task { await model.newFolder() } }
                Button("Upload Files…") { chooseUpload() }
                if !model.selection.isEmpty {
                    Divider()
                    if !model.session.isLocal {
                        Button("Download…") { chooseDownload() }
                    }
                    Button("Duplicate") { Task { await model.duplicateSelection() } }
                    Button("Copy Path") { model.copyPaths() }
                    if model.canRevealSelection {
                        Button("Reveal in Finder") { Task { await model.revealInFinder() } }
                    }
                    Divider()
                    Button("Move to Trash") {
                        Task { await model.trashSelection(permanently: false) }
                    }
                    Button("Delete Immediately…", role: .destructive) { confirmDelete = true }
                }
                Divider()
                Button("Refresh") { model.refresh() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Actions")
        }
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(8))
        .background(DashSkin.panel)
    }

    @ViewBuilder
    private var sortItems: some View {
        ForEach(FileSortKey.allCases, id: \.self) { key in
            Button {
                if model.sortKey == key {
                    model.sortAscending.toggle()
                } else {
                    model.sortKey = key
                    model.sortAscending = true
                }
            } label: {
                Label(
                    key.title,
                    systemImage: model.sortKey == key
                        ? (model.sortAscending ? "chevron.up" : "chevron.down") : "")
            }
        }
        Divider()
        Toggle("Show Hidden Files", isOn: $model.showHidden)
    }

    private var viewModeBinding: Binding<FileViewMode> {
        Binding(get: { model.viewMode }, set: { model.viewMode = $0 })
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            if model.viewMode == .icon {
                FinderIconView(model: model)
            } else {
                FinderListView(model: model, columns: layout.columns)
            }
            if model.projectingEntries || (model.loading && model.entries.isEmpty) {
                FinderSkeleton(mode: model.viewMode, iconSize: model.iconSize, dark: dark)
            } else if model.visibleEntries.isEmpty, !model.loading, !model.projectingEntries {
                Text(model.errorMessage ?? "This folder is empty.")
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
        .onDrop(
            of: [MachineItemsPayload.typeIdentifier, UTType.fileURL.identifier],
            isTargeted: nil
        ) { providers in
            let option = NSEvent.modifierFlags.contains(.option)
            let destination = model.path
            Task {
                await model.handleDrop(
                    providers: providers, destination: destination, optionHeld: option)
            }
            return true
        }
    }

    private var pathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: UIScale.pt(3)) {
                ForEach(FileListing.breadcrumbs(for: model.path), id: \.path) { crumb in
                    Button {
                        model.navigate(to: crumb.path)
                        model.requestKeyFocus()
                    } label: {
                        HStack(spacing: UIScale.pt(4)) {
                            Image(
                                systemName: crumb.path == "/" ? "externaldrive" : "folder"
                            )
                            .font(.system(size: UIScale.pt(9.5)))
                            Text(crumb.name)
                                .font(.system(size: UIScale.pt(11)))
                        }
                        .foregroundStyle(
                            crumb.path == model.path
                                ? DashSkin.ink(dark) : DashSkin.inkFaint(dark))
                    }
                    .buttonStyle(.edith(.borderless))
                    if crumb.path != model.path {
                        Image(systemName: "chevron.compact.right")
                            .font(.system(size: UIScale.pt(9)))
                            .foregroundStyle(DashSkin.inkFaint(dark).opacity(0.5))
                    }
                }
            }
            .padding(.horizontal, UIScale.pt(12))
            .padding(.vertical, UIScale.pt(5))
        }
        .background(DashSkin.panel)
    }

    private var statusBar: some View {
        HStack(spacing: UIScale.pt(8)) {
            if let progress = model.progress {
                LoadingProgress(value: progress.fraction)
                    .frame(width: UIScale.pt(90))
                Text(progress.description)
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(DashSkin.ink(dark))
                    .lineLimit(1)
                if model.canCancelTransfer {
                    Button {
                        model.cancelTransfer()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.edith(.iconOnly))
                    .help("Cancel transfer")
                    .accessibilityLabel("Cancel transfer")
                }
            } else if let message = model.statusMessage ?? model.errorMessage {
                Text(message)
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(
                        model.errorMessage == nil ? DashSkin.inkFaint(dark) : DashSkin.danger
                    )
                    .lineLimit(1)
            } else {
                Text(model.statusLine)
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            Spacer(minLength: 0)
            if model.loading {
                SkeletonGroup {
                    SkeletonBlock(width: 12, height: 12, corner: 6)
                }
                .accessibilityLabel("Loading folder")
            }
            if model.viewMode == .icon {
                Slider(value: $model.iconSize, in: 40...128)
                    .controlSize(.mini)
                    .frame(width: UIScale.pt(90))
                    .help("Icon size")
            }
        }
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(4))
        .background(DashSkin.panel)
    }

    private func chooseUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await model.upload(urls) }
    }

    private func chooseDownload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Download Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.download(to: url) }
    }
}

struct FinderRowContextMenu: View {
    let model: FinderModel
    let entry: RemoteFileEntry

    var body: some View {
        Button("Open") { model.open(entry) }
        if entry.isDirectory {
            Button("Open in New Window") {
                FinderWindow.open(session: model.session, path: entry.path)
            }
        } else {
            Button("Quick Look") { model.quickLookPath = entry.path }
        }
        Divider()
        Button("Rename") { model.beginRename(entry) }
        Button("Duplicate") {
            model.focusContext(on: entry)
            Task { await model.duplicateSelection() }
        }
        Button("Copy Path") {
            model.focusContext(on: entry)
            model.copyPaths()
        }
        Divider()
        Button("Move to Trash", role: .destructive) {
            model.focusContext(on: entry)
            Task { await model.trashSelection(permanently: false) }
        }
    }
}

@MainActor
enum FinderWindow {
    static func open(session: MachineSession, path: String? = nil) {
        guard let client = session.uiClient else {
            MachinesModel.shared.operationError = "The owning app window bridge is unavailable."
            return
        }
        client.enqueue {
            try await client.openWindow(.init(
                    kind: .files, machineID: session.id, path: path, title: session.machine.name,
                    subtitle: path ?? (session.isLocal ? "Home" : "Files")))
        }
    }
}
