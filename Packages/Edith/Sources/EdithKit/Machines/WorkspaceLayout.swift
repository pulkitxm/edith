import Foundation

public enum PaneScreen: String, Codable, CaseIterable, Sendable {
    case overview, processes, docker, terminal, files, tools
}

public struct PaneTarget: Codable, Hashable, Sendable {
    public var machineID: UUID
    public var screen: PaneScreen
    public var argument: String?

    public init(machineID: UUID, screen: PaneScreen, argument: String? = nil) {
        self.machineID = machineID
        self.screen = screen
        self.argument = argument
    }
}

public struct PaneTab: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var target: PaneTarget
    public var titleOverride: String?

    public init(id: UUID = UUID(), target: PaneTarget, titleOverride: String? = nil) {
        self.id = id
        self.target = target
        self.titleOverride = titleOverride
    }
}

public struct PaneNode: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var tabs: [PaneTab]
    public var selected: UUID

    public init(id: UUID = UUID(), tabs: [PaneTab], selected: UUID) {
        self.id = id
        self.tabs = tabs
        self.selected = selected
    }
}

public indirect enum LayoutNode: Codable, Identifiable, Hashable, Sendable {
    case pane(PaneNode)
    case split(SplitNode)

    public var id: UUID {
        switch self {
        case let .pane(pane): return pane.id
        case let .split(split): return split.id
        }
    }
}

public struct SplitNode: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var axis: SplitAxis
    public var children: [LayoutNode]
    public var ratios: [Double]

    public init(id: UUID = UUID(), axis: SplitAxis, children: [LayoutNode], ratios: [Double]) {
        self.id = id
        self.axis = axis
        self.children = children
        self.ratios = ratios
    }
}

public enum SplitAxis: String, Codable, Sendable {
    case horizontal
    case vertical
}

public enum InsertSide: String, Codable, Sendable {
    case left, right, top, bottom

    public var axis: SplitAxis { self == .left || self == .right ? .horizontal : .vertical }
    public var isBefore: Bool { self == .left || self == .top }
}

public struct WorkspaceLayout: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var root: LayoutNode
    public var focused: UUID
    public var maximized: UUID?

    public init(
        id: UUID = UUID(), name: String, root: LayoutNode, focused: UUID, maximized: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.root = root
        self.focused = focused
        self.maximized = maximized
    }
}

extension LayoutNode {
    public var panes: [PaneNode] {
        switch self {
        case let .pane(pane): return [pane]
        case let .split(split): return split.children.flatMap(\.panes)
        }
    }

    public func pane(_ id: UUID) -> PaneNode? {
        panes.first { $0.id == id }
    }

    public mutating func updatePane(_ id: UUID, _ body: (inout PaneNode) -> Void) {
        switch self {
        case var .pane(pane):
            guard pane.id == id else { return }
            body(&pane)
            self = .pane(pane)
        case var .split(split):
            for index in split.children.indices {
                split.children[index].updatePane(id, body)
            }
            self = .split(split)
        }
    }

    public mutating func insert(_ node: LayoutNode, near targetID: UUID, side: InsertSide) {
        if id == targetID {
            if case var .split(split) = self, split.axis == side.axis {
                let share = 1.0 / Double(split.children.count + 1)
                let at = side.isBefore ? 0 : split.children.count
                split.ratios = split.ratios.map { $0 * (1 - share) }
                split.ratios.insert(share, at: at)
                split.children.insert(node, at: at)
                self = .split(split)
            } else {
                self = .split(
                    SplitNode(
                        axis: side.axis,
                        children: side.isBefore ? [node, self] : [self, node],
                        ratios: [0.5, 0.5]))
            }
            normalize()
            return
        }
        guard case var .split(split) = self else { return }
        if let index = split.children.firstIndex(where: { $0.id == targetID }) {
            if split.axis == side.axis {
                let at = side.isBefore ? index : index + 1
                let share = 1.0 / Double(split.children.count + 1)
                split.ratios = split.ratios.map { $0 * (1 - share) }
                split.ratios.insert(share, at: at)
                split.children.insert(node, at: at)
            } else {
                split.children[index].insert(node, near: targetID, side: side)
            }
        } else {
            for index in split.children.indices {
                split.children[index].insert(node, near: targetID, side: side)
            }
        }
        self = .split(split)
        normalize()
    }

    @discardableResult
    public mutating func remove(_ targetID: UUID) -> Bool {
        guard case var .split(split) = self else { return false }
        if let index = split.children.firstIndex(where: { $0.id == targetID }) {
            split.children.remove(at: index)
            split.ratios.remove(at: index)
            self = .split(split)
            normalize()
            return true
        }
        var removed = false
        for index in split.children.indices where !removed {
            removed = split.children[index].remove(targetID)
        }
        self = .split(split)
        if removed { normalize() }
        return removed
    }

    public mutating func normalize() {
        guard case var .split(split) = self else { return }
        var index = 0
        while index < split.children.count {
            split.children[index].normalize()
            if case let .split(child) = split.children[index] {
                if child.children.isEmpty {
                    split.children.remove(at: index)
                    split.ratios.remove(at: index)
                    continue
                }
                if child.children.count == 1 {
                    split.children[index] = child.children[0]
                    index += 1
                    continue
                }
                if child.axis == split.axis {
                    let outer = split.ratios[index]
                    split.children.remove(at: index)
                    split.ratios.remove(at: index)
                    for (offset, grandchild) in child.children.enumerated() {
                        split.children.insert(grandchild, at: index + offset)
                        split.ratios.insert(child.ratios[offset] * outer, at: index + offset)
                    }
                    index += child.children.count
                    continue
                }
            }
            index += 1
        }
        let total = split.ratios.reduce(0, +)
        if total > 0 {
            split.ratios = split.ratios.map { $0 / total }
        } else if !split.ratios.isEmpty {
            split.ratios = Array(
                repeating: 1.0 / Double(split.ratios.count), count: split.ratios.count)
        }
        if split.children.count == 1 {
            self = split.children[0]
        } else {
            self = .split(split)
        }
    }

    public mutating func equalize() {
        guard case var .split(split) = self else { return }
        for index in split.children.indices { split.children[index].equalize() }
        split.ratios = Array(
            repeating: 1.0 / Double(split.children.count), count: split.children.count)
        self = .split(split)
    }
}

public enum WorkspaceGeometry {
    public static func frames(
        node: LayoutNode, in rect: CGRect, gap: CGFloat, into result: inout [UUID: CGRect]
    ) {
        switch node {
        case let .pane(pane):
            result[pane.id] = rect
        case let .split(split):
            let count = CGFloat(split.children.count)
            let horizontal = split.axis == .horizontal
            let available = (horizontal ? rect.width : rect.height) - gap * (count - 1)
            var offset: CGFloat = horizontal ? rect.minX : rect.minY
            for (index, child) in split.children.enumerated() {
                let length = available * CGFloat(split.ratios[index])
                let childRect =
                    horizontal
                    ? CGRect(x: offset, y: rect.minY, width: length, height: rect.height)
                    : CGRect(x: rect.minX, y: offset, width: rect.width, height: length)
                frames(node: child, in: childRect, gap: gap, into: &result)
                offset += length + gap
            }
        }
    }
}

extension PaneScreen {
    public var title: String {
        switch self {
        case .overview: return "Overview"
        case .processes: return "Processes"
        case .docker: return "Docker"
        case .terminal: return "Terminal"
        case .files: return "Files"
        case .tools: return "Tools"
        }
    }

    public var icon: String {
        switch self {
        case .overview: return "gauge.with.needle"
        case .processes: return "list.bullet.rectangle"
        case .docker: return "shippingbox"
        case .terminal: return "terminal"
        case .files: return "folder"
        case .tools: return "wrench.and.screwdriver"
        }
    }

    public static func available(isLocal: Bool, hasDocker: Bool) -> [PaneScreen] {
        if isLocal { return [.overview, .processes, .files, .terminal] }
        return PaneScreen.allCases.filter { $0 != .docker || hasDocker }
    }
}

extension WorkspaceLayout {
    public static func single(machineID: UUID, screen: PaneScreen = .overview) -> WorkspaceLayout {
        let tab = PaneTab(target: PaneTarget(machineID: machineID, screen: screen))
        let pane = PaneNode(tabs: [tab], selected: tab.id)
        return WorkspaceLayout(name: "Workspace", root: .pane(pane), focused: pane.id)
    }

    public static func tiled(
        machineIDs: [UUID], screen: PaneScreen, name: String
    ) -> WorkspaceLayout? {
        guard !machineIDs.isEmpty else { return nil }
        let panes = machineIDs.map { id -> LayoutNode in
            let tab = PaneTab(target: PaneTarget(machineID: id, screen: screen))
            return .pane(PaneNode(tabs: [tab], selected: tab.id))
        }
        guard panes.count > 1 else {
            return WorkspaceLayout(
                name: name, root: panes[0], focused: panes[0].id)
        }
        let ratio = 1.0 / Double(panes.count)
        let root = LayoutNode.split(
            SplitNode(
                axis: .horizontal, children: panes,
                ratios: Array(repeating: ratio, count: panes.count)))
        return WorkspaceLayout(name: name, root: root, focused: panes[0].id)
    }

    public static func comparison(machineIDs: [UUID]) -> WorkspaceLayout? {
        tiled(machineIDs: Array(machineIDs.prefix(2)), screen: .overview, name: "Compare")
    }

    public var paneCount: Int { root.panes.count }

    public var allTargets: [PaneTarget] {
        root.panes.flatMap { $0.tabs.map(\.target) }
    }

    public func subscribedMachines() -> Set<UUID> {
        Set(allTargets.map(\.machineID))
    }

    public mutating func retarget(from oldMachine: UUID, to newMachine: UUID) {
        for pane in root.panes {
            root.updatePane(pane.id) { node in
                for index in node.tabs.indices
                where node.tabs[index].target.machineID
                    == oldMachine
                {
                    node.tabs[index].target.machineID = newMachine
                }
            }
        }
    }

    public mutating func closePane(_ paneID: UUID) {
        guard paneCount > 1 else { return }
        root.remove(paneID)
        if focused == paneID { focused = root.panes.first?.id ?? focused }
        if maximized == paneID { maximized = nil }
    }

    public mutating func split(paneID: UUID, side: InsertSide, target: PaneTarget) {
        let tab = PaneTab(target: target)
        let pane = PaneNode(tabs: [tab], selected: tab.id)
        root.insert(.pane(pane), near: paneID, side: side)
        focused = pane.id
    }
}

public struct WorkspaceStore: Codable, Sendable {
    public var layouts: [WorkspaceLayout]
    public var currentID: UUID?

    public init(layouts: [WorkspaceLayout] = [], currentID: UUID? = nil) {
        self.layouts = layouts
        self.currentID = currentID
    }

    public var current: WorkspaceLayout? {
        guard let currentID else { return layouts.first }
        return layouts.first { $0.id == currentID } ?? layouts.first
    }

    public mutating func upsert(_ layout: WorkspaceLayout) {
        if let index = layouts.firstIndex(where: { $0.id == layout.id }) {
            layouts[index] = layout
        } else {
            layouts.append(layout)
        }
        currentID = layout.id
    }

    public mutating func remove(_ id: UUID) {
        layouts.removeAll { $0.id == id }
        if currentID == id { currentID = layouts.first?.id }
    }
}

extension MachinePaths {
    public static var workspacesFile: URL {
        dir.appendingPathComponent("workspaces.json")
    }
}

extension LayoutNode {
    public mutating func updateSplit(_ id: UUID, _ body: (inout SplitNode) -> Void) {
        guard case var .split(split) = self else { return }
        if split.id == id {
            body(&split)
            self = .split(split)
            return
        }
        for index in split.children.indices {
            split.children[index].updateSplit(id, body)
        }
        self = .split(split)
    }
}

extension WorkspaceStore {
    public static func load(from file: URL = MachinePaths.workspacesFile) -> WorkspaceStore {
        guard let data = try? Data(contentsOf: file),
            let store = try? JSONDecoder().decode(WorkspaceStore.self, from: data)
        else { return WorkspaceStore() }
        return store
    }

    public static func save(_ store: WorkspaceStore, to file: URL = MachinePaths.workspacesFile)
        throws
    {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(store).write(to: file, options: .atomic)
    }
}
