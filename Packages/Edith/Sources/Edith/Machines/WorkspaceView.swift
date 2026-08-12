import AppKit
import EdithKit
import SwiftUI

@MainActor
final class WorkspaceModel: ObservableObject {
    static let shared = WorkspaceModel(machines: .shared)

    @Published var layout: WorkspaceLayout
    @Published var store: WorkspaceStore

    private let file: URL

    init(machines: MachinesModel, file: URL = MachinePaths.workspacesFile) {
        self.file = file
        let loaded = WorkspaceModel.load(file)
        let fallback = WorkspaceLayout.single(
            machineID: machines.allMachines.first?.id ?? MachinesModel.localMachineID)
        store = loaded ?? WorkspaceStore(layouts: [fallback], currentID: fallback.id)
        layout = loaded?.current ?? fallback
    }

    func persist() {
        store.upsert(layout)
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private static func load(_ file: URL) -> WorkspaceStore? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(WorkspaceStore.self, from: data)
    }

    func apply(_ change: (inout WorkspaceLayout) -> Void) {
        change(&layout)
        persist()
    }

    func applyWithoutPersisting(_ change: (inout WorkspaceLayout) -> Void) {
        change(&layout)
    }

    func use(_ preset: WorkspaceLayout) {
        let live = Set(preset.root.panes.flatMap { $0.tabs.map(\.id) })
        layout = preset
        store.layouts = [preset]
        store.currentID = preset.id
        persist()
        PaneViewStore.shared.releaseAll(except: live)
    }

    func retargetPane(_ paneID: UUID, tabID: UUID, to target: PaneTarget) {
        apply { layout in
            layout.root.updatePane(paneID) { pane in
                guard let index = pane.tabs.firstIndex(where: { $0.id == tabID }) else { return }
                pane.tabs[index].target = target
            }
        }
    }

    func addTab(to paneID: UUID, target: PaneTarget) {
        apply { layout in
            layout.root.updatePane(paneID) { pane in
                let tab = PaneTab(target: target)
                pane.tabs.append(tab)
                pane.selected = tab.id
            }
        }
    }

    @discardableResult
    func cycleTab(backwards: Bool) -> Bool {
        guard let pane = layout.root.pane(layout.focused) ?? layout.root.panes.first,
            pane.tabs.count > 1,
            let index = pane.tabs.firstIndex(where: { $0.id == pane.selected })
        else { return false }
        let count = pane.tabs.count
        let next = backwards ? (index - 1 + count) % count : (index + 1) % count
        let target = pane.tabs[next].id
        apply { layout in
            layout.focused = pane.id
            layout.root.updatePane(pane.id) { $0.selected = target }
        }
        return true
    }

    @discardableResult
    func cyclePane(backwards: Bool) -> Bool {
        let panes = layout.root.panes
        guard panes.count > 1 else { return false }
        let current = panes.firstIndex { $0.id == layout.focused } ?? 0
        let next =
            backwards
            ? (current - 1 + panes.count) % panes.count
            : (current + 1) % panes.count
        let target = panes[next].id
        apply { $0.focused = target }
        return true
    }

    @discardableResult
    func closeFocusedTab() -> Bool {
        guard let pane = layout.root.pane(layout.focused) ?? layout.root.panes.first else {
            return false
        }
        let tabID = pane.selected
        if pane.tabs.count > 1 {
            closeTab(tabID, in: pane.id)
            PaneViewStore.shared.release(tabID: tabID)
            return true
        }
        guard layout.paneCount > 1 else { return false }
        let orphans = pane.tabs.map(\.id)
        apply { $0.closePane(pane.id) }
        for id in orphans { PaneViewStore.shared.release(tabID: id) }
        return true
    }

    func closeTab(_ tabID: UUID, in paneID: UUID) {
        var shouldClosePane = false
        apply { layout in
            layout.root.updatePane(paneID) { pane in
                guard pane.tabs.count > 1 else {
                    shouldClosePane = true
                    return
                }
                pane.tabs.removeAll { $0.id == tabID }
                if pane.selected == tabID { pane.selected = pane.tabs.first?.id ?? pane.selected }
            }
        }
        if shouldClosePane { apply { $0.closePane(paneID) } }
    }
}

struct WorkspaceView: View {
    @ObservedObject var machines: MachinesModel
    @ObservedObject private var model = WorkspaceModel.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.machineConnectionsEnabled) private var connectionsEnabled

    private var dark: Bool { scheme == .dark }

    init(machines: MachinesModel) {
        self.machines = machines
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.4)
            GeometryReader { proxy in
                WorkspaceNodeView(
                    node: model.layout.root, model: model, machines: machines,
                    size: proxy.size, dark: dark)
            }
        }
        .background(DashSkin.paper(dark))
        .onAppear {
            if connectionsEnabled { machines.connectAll() }
        }
    }

    private var toolbar: some View {
        HStack(spacing: UIScale.pt(8)) {
            Menu {
                Button("Compare two machines") { usePreset(.comparison) }
                Button("Docker everywhere") { usePreset(.docker) }
                Button("Terminal grid") { usePreset(.terminals) }
                Button("Files side by side") { usePreset(.files) }
                Divider()
                Button("Single pane") { usePreset(.single) }
            } label: {
                Label("Layout", systemImage: "rectangle.split.2x1")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose a layout")

            Button {
                model.apply { $0.root.equalize() }
            } label: {
                Image(systemName: "equal.square")
            }
            .buttonStyle(HoverButtonStyle())
            .help("Even out the panes")

            Text("\(model.layout.paneCount) pane\(model.layout.paneCount == 1 ? "" : "s")")
                .font(.system(size: UIScale.pt(10.5)))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, UIScale.pt(14))
        .padding(.vertical, UIScale.pt(7))
    }

    private enum Preset {
        case comparison
        case docker
        case terminals
        case files
        case single
    }

    private func usePreset(_ preset: Preset) {
        let ids = machines.allMachines.map(\.id)
        let remote = machines.allMachines.filter { !machines.isLocal($0.id) }.map(\.id)
        switch preset {
        case .comparison:
            if let layout = WorkspaceLayout.comparison(machineIDs: ids) { model.use(layout) }
        case .docker:
            let targets = remote
            if let layout = WorkspaceLayout.tiled(
                machineIDs: targets, screen: .docker, name: "Docker")
            {
                model.use(layout)
            }
        case .terminals:
            if let layout = WorkspaceLayout.tiled(
                machineIDs: ids, screen: .terminal, name: "Terminals")
            {
                model.use(layout)
            }
        case .files:
            if let layout = WorkspaceLayout.tiled(
                machineIDs: Array(ids.prefix(2)), screen: .files, name: "Files")
            {
                model.use(layout)
            }
        case .single:
            model.use(WorkspaceLayout.single(machineID: ids.first ?? MachinesModel.localMachineID))
        }
    }
}

struct WorkspaceNodeView: View {
    let node: LayoutNode
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var machines: MachinesModel
    let size: CGSize
    let dark: Bool

    private static let dividerWidth: CGFloat = 6

    var body: some View {
        switch node {
        case let .pane(pane):
            WorkspacePaneView(pane: pane, model: model, machines: machines, dark: dark)
                .frame(width: size.width, height: size.height)
        case let .split(split):
            splitBody(split)
        }
    }

    @ViewBuilder
    private func splitBody(_ split: SplitNode) -> some View {
        let horizontal = split.axis == .horizontal
        let dividers = CGFloat(split.children.count - 1) * Self.dividerWidth
        let available = (horizontal ? size.width : size.height) - dividers
        let layout =
            horizontal
            ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        layout {
            ForEach(Array(split.children.enumerated()), id: \.element.id) { index, child in
                let length = max(60, available * split.ratios[index])
                WorkspaceNodeView(
                    node: child, model: model, machines: machines,
                    size: horizontal
                        ? CGSize(width: length, height: size.height)
                        : CGSize(width: size.width, height: length),
                    dark: dark
                )
                .frame(
                    width: horizontal ? length : size.width,
                    height: horizontal ? size.height : length)
                if index < split.children.count - 1 {
                    WorkspaceDivider(
                        axis: split.axis, dark: dark,
                        onDrag: { delta in
                            resize(split: split, index: index, delta: delta, available: available)
                        },
                        onCommit: { model.persist() },
                        onEqualize: {
                            model.apply { layout in
                                layout.root.updateSplit(split.id) { node in
                                    node.ratios = Array(
                                        repeating: 1.0 / Double(node.children.count),
                                        count: node.children.count)
                                }
                            }
                        })
                }
            }
        }
    }

    private func resize(split: SplitNode, index: Int, delta: CGFloat, available: CGFloat) {
        guard available > 0 else { return }
        let change = Double(delta / available)
        model.applyWithoutPersisting { layout in
            layout.root.updateSplit(split.id) { node in
                guard index + 1 < node.ratios.count else { return }
                let minimum = 0.08
                let first = node.ratios[index] + change
                let second = node.ratios[index + 1] - change
                guard first >= minimum, second >= minimum else { return }
                node.ratios[index] = first
                node.ratios[index + 1] = second
            }
        }
    }
}

private struct WorkspaceDivider: View {
    let axis: SplitAxis
    let dark: Bool
    let onDrag: (CGFloat) -> Void
    let onCommit: () -> Void
    let onEqualize: () -> Void
    @State private var hovering = false
    @State private var lastTranslation: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(hovering ? DashSkin.accent(dark).opacity(0.5) : DashSkin.line(dark))
            .frame(
                width: axis == .horizontal ? 6 : nil,
                height: axis == .horizontal ? nil : 6
            )
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside {
                    if axis == .horizontal {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.resizeUpDown.push()
                    }
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let travelled =
                            axis == .horizontal
                            ? value.translation.width : value.translation.height
                        onDrag(travelled - lastTranslation)
                        lastTranslation = travelled
                    }
                    .onEnded { _ in
                        lastTranslation = 0
                        onCommit()
                    }
            )
            .onTapGesture(count: 2, perform: onEqualize)
    }
}
