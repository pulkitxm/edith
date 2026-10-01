import EdithDatabase
import EdithKit
import SwiftUI

struct DatabaseWorkbenchView: View {
    let connections: DatabaseConnectionWorkspaceModel
    let explorer: DatabaseObjectExplorerModel
    let tabs: DatabaseTableTabsModel
    let mutations: DatabaseWorkspaceModel
    var showsObjectNavigator = true
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        AppTheme.accent.rawValue
    @Environment(\.automaticViewActionsEnabled) private var automaticViewActionsEnabled
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme
    @State private var objectListPresented = false

    private var tableBinding: Binding<String> {
        Binding(
            get: { tabs.selectedID?.uuidString ?? "" },
            set: { raw in
                guard let id = UUID(uuidString: raw) else { return }
                tabs.select(id)
            })
    }

    private var modeBinding: Binding<String> {
        Binding(
            get: { tabs.selected?.mode.rawValue ?? "" },
            set: { raw in
                guard let mode = DatabaseWorkbenchMode(rawValue: raw), let tab = tabs.selected,
                    let connection = connections.selectedConnection
                else { return }
                tab.selectMode(mode, connection: connection)
            })
    }

    private func tableIsValid(_ raw: String) -> Bool {
        guard let id = UUID(uuidString: raw) else { return false }
        return tabs.tabs.contains { $0.id == id }
    }

    private func modeIsValid(_ raw: String) -> Bool {
        DatabaseWorkbenchMode(rawValue: raw) != nil
    }

    private var palette: DatabaseThemePalette {
        DatabaseThemePalette(dark: scheme == .dark, theme: AppTheme(storedName: themeName))
    }

    var body: some View {
        Group {
            if let connection = connections.selectedConnection {
                session(connection)
            } else {
                DatabaseWorkbenchEmptyState(
                    symbol: "cylinder.split.1x2", title: "Choose a connection",
                    detail: "Select a connection or add one to start working with data.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.canvas)
        .navigationRoute("mode", selection: modeBinding, isValid: modeIsValid)
        .navigationRoute("table", selection: tableBinding, isValid: tableIsValid)
        .task(id: connections.selectedConnection) {
            guard automaticViewActionsEnabled else { return }
            tabs.prepare(for: connections.selectedConnection)
            explorer.prepare(for: connections.selectedConnection)
        }
    }

    @ViewBuilder
    private func session(_ connection: DatabaseConnectionSummary) -> some View {
        switch connections.selectedSessionState {
        case .disconnected: disconnected(connection)
        case .connecting:
            SkeletonReplica("Connecting to \(connection.name)") { workspace(connection) }
        case .connected:
            workspace(connection).task(id: connection.id) {
                guard automaticViewActionsEnabled else { return }
                explorer.load(connection)
            }
        case .disconnecting:
            SkeletonReplica("Disconnecting from \(connection.name)") { disconnected(connection) }
        case .failed(let message, _), .outcomeUnknown(let message, _):
            VStack(spacing: UIScale.pt(12)) {
                DatabaseWorkbenchEmptyState(
                    symbol: "exclamationmark.triangle", title: "Connection unavailable",
                    detail: message)
                Button("Try again") { Task { await connections.connectSelected() } }
                    .buttonStyle(.edith(.primary, tint: palette.accent))
            }.padding(UIScale.pt(24))
        }
    }

    private func disconnected(_ connection: DatabaseConnectionSummary) -> some View {
        VStack(spacing: UIScale.pt(16)) {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: UIScale.pt(40), weight: .light))
                .foregroundStyle(palette.accent)
            Text(connection.name).font(.system(size: UIScale.pt(21), weight: .semibold))
            Text("\(connection.product.displayName) · \(connection.environmentLabel)")
                .font(.system(size: UIScale.pt(12))).foregroundStyle(.secondary)
            Button("Connect") { Task { await connections.connectSelected() } }
                .buttonStyle(.edith(.primary, tint: palette.accent))
                .keyboardShortcut(.defaultAction)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func workspace(_ connection: DatabaseConnectionSummary) -> some View {
        Group {
            if compact {
                VStack(spacing: 0) {
                    objectPicker(connection)
                    Divider()
                    activeRegion(connection)
                }
            } else if showsObjectNavigator {
                HSplitView {
                    DatabaseObjectNavigatorView(
                        explorer: explorer, connection: connection,
                        open: { open($0, connection: connection) }
                    )
                    .frame(
                        minWidth: UIScale.pt(190), idealWidth: UIScale.pt(225),
                        maxWidth: UIScale.pt(300))
                    activeRegion(connection).frame(minWidth: UIScale.pt(460))
                }
            } else {
                activeRegion(connection)
            }
        }
        .onChange(of: explorer.selectedObject) { _, object in
            guard let object, tabs.data.selectedObject != object else { return }
            open(object, connection: connection)
        }
    }

    private func activeRegion(_ connection: DatabaseConnectionSummary) -> some View {
        VStack(spacing: 0) {
            tabBar
            ZStack {
                if tabs.tabs.isEmpty {
                    DatabaseWorkbenchTabView(
                        connections: connections, explorer: explorer, mutations: mutations,
                        connection: connection, tab: nil, data: tabs.data, isActive: true,
                        palette: palette)
                }
                ForEach(tabs.tabs) { tab in
                    DatabaseWorkbenchTabView(
                        connections: connections, explorer: explorer, mutations: mutations,
                        connection: connection, tab: tab, data: tab.data,
                        isActive: tabs.selectedID == tab.id, palette: palette
                    )
                    .opacity(tabs.selectedID == tab.id ? 1 : 0)
                    .allowsHitTesting(tabs.selectedID == tab.id)
                    .accessibilityHidden(tabs.selectedID != tab.id)
                    .disabled(tabs.selectedID != tab.id)
                }
            }.transaction { $0.animation = nil }
        }
    }

    private var tabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: UIScale.pt(3)) {
                    ForEach(tabs.tabs) { tab in
                        HStack(spacing: UIScale.pt(8)) {
                            Button {
                                tabs.select(tab.id)
                                explorer.select(tab.object)
                            } label: {
                                Label(tab.object.path.last ?? "Table", systemImage: "tablecells")
                                    .font(.system(size: UIScale.pt(11), weight: .medium))
                            }
                            .buttonStyle(.edith(.borderless))
                            .accessibilityAddTraits(tabs.selectedID == tab.id ? .isSelected : [])
                            Button {
                                tabs.close(tab.id)
                                explorer.select(tabs.selected?.object)
                            } label: {
                                Image(systemName: "xmark").font(
                                    .system(size: UIScale.pt(9), weight: .semibold))
                            }
                            .buttonStyle(.edith(.borderless))
                            .accessibilityLabel("Close \(tab.object.path.last ?? "table") tab")
                        }
                        .foregroundStyle(tabs.selectedID == tab.id ? palette.ink : palette.inkFaint)
                        .padding(.horizontal, UIScale.pt(10)).frame(height: UIScale.pt(34))
                        .background(
                            tabs.selectedID == tab.id ? palette.canvas : palette.panel,
                            in: RoundedRectangle(cornerRadius: UIScale.pt(6))
                        )
                        .help(tab.object.path.joined(separator: "."))
                        .id(tab.id)
                    }
                }.padding(.horizontal, UIScale.pt(6)).padding(.vertical, UIScale.pt(4))
            }
            .onChange(of: tabs.selectedID) { _, id in if let id { proxy.scrollTo(id) } }
        }
        .frame(height: UIScale.pt(42)).background(palette.panel)
    }

    private func objectPicker(_ connection: DatabaseConnectionSummary) -> some View {
        HStack {
            Button {
                objectListPresented = true
            } label: {
                Label(
                    explorer.selectedObject?.path.last ?? "Select an object",
                    systemImage: "tablecells"
                )
                .font(.system(size: UIScale.pt(11), weight: .medium))
            }
            .popover(isPresented: $objectListPresented, arrowEdge: .bottom) {
                List {
                    ForEach(explorer.groups) { group in
                        Section(group.title) {
                            switch group.state {
                            case .idle, .failed:
                                Button("Load \(group.title)") {
                                    explorer.loadGroup(group.identifier, connection: connection)
                                }
                            case .loading:
                                SkeletonReplica("Loading \(group.title)") {
                                    Text("Loading objects")
                                }
                            case .loaded:
                                if group.objects.isEmpty { Text("No objects") }
                            }
                            ForEach(group.objects) { object in
                                Button(object.title) {
                                    open(object.identifier, connection: connection)
                                    objectListPresented = false
                                }
                            }
                            if group.nextContinuation != nil {
                                Button("Load more objects") {
                                    explorer.loadGroup(
                                        group.identifier, connection: connection, appending: true)
                                }
                            }
                        }
                    }
                }
                .frame(width: UIScale.pt(280), height: UIScale.pt(360))
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .disabled(explorer.groups.isEmpty)
            Spacer()
            Button {
                explorer.load(connection, force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.edith(.borderless)).accessibilityLabel("Reload database objects")
        }
        .padding(.horizontal, UIScale.pt(12)).frame(height: UIScale.pt(42)).background(
            palette.panel)
    }

    private func open(_ object: DatabaseObjectIdentifier, connection: DatabaseConnectionSummary) {
        tabs.open(object, connection: connection)
        explorer.select(object)
    }
}

struct DatabaseWorkbenchEmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: UIScale.pt(11)) {
            Image(systemName: symbol).font(.system(size: UIScale.pt(32), weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: UIScale.pt(17), weight: .semibold))
            Text(detail).font(.system(size: UIScale.pt(12))).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: UIScale.pt(410))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(UIScale.pt(26))
    }
}
