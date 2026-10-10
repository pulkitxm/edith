import EdithExtensionSupport
import Foundation

public enum WorkspaceOperation: String, CaseIterable, Sendable {
    case list
    case split
    case close
    case point
    case equalize
    case create
    case use
    case rename
    case remove

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "machines.workspace.\(rawValue)"),
            summary: summary, cli: ["machines", "workspace", command], effect: effect)
    }

    private var command: String {
        switch self {
        case .list: "ls"
        case .create: "new"
        case .remove: "rm"
        default: rawValue
        }
    }

    private var summary: String {
        switch self {
        case .list: "List saved machine workspaces."
        case .split: "Split a workspace pane."
        case .close: "Close a workspace pane."
        case .point: "Point a workspace pane at another target."
        case .equalize: "Equalize workspace split ratios."
        case .create: "Create a machine workspace."
        case .use: "Make a saved workspace current."
        case .rename: "Rename a saved workspace."
        case .remove: "Remove a saved workspace."
        }
    }

    private var effect: UserOperationEffect {
        switch self {
        case .list: .read
        case .close, .remove: .destructive
        case .split, .point, .equalize, .create, .use, .rename: .write
        }
    }
}

public struct WorkspaceTabRetarget: Equatable, Sendable {
    public let tabID: UUID
    public let target: PaneTarget

    public init(tabID: UUID, target: PaneTarget) {
        self.tabID = tabID
        self.target = target
    }
}

public enum WorkspaceOperationRequest: Equatable, Sendable {
    case list
    case split(workspaceID: UUID, paneID: UUID, side: InsertSide, target: PaneTarget)
    case close(workspaceID: UUID, paneID: UUID)
    case point(workspaceID: UUID, paneID: UUID, targets: [WorkspaceTabRetarget])
    case equalize(workspaceID: UUID, splitID: UUID? = nil)
    case create(WorkspaceLayout)
    case use(workspaceID: UUID)
    case rename(workspaceID: UUID, name: String)
    case remove(workspaceID: UUID)

    public var operation: WorkspaceOperation {
        switch self {
        case .list: .list
        case .split: .split
        case .close: .close
        case .point: .point
        case .equalize: .equalize
        case .create: .create
        case .use: .use
        case .rename: .rename
        case .remove: .remove
        }
    }
}

public struct WorkspaceOperationResult: Equatable, Sendable {
    public let operation: WorkspaceOperation
    public let layouts: [WorkspaceLayout]
    public let layout: WorkspaceLayout?
    public let removed: WorkspaceLayout?
    public let changed: Bool

    public init(
        operation: WorkspaceOperation, layouts: [WorkspaceLayout],
        layout: WorkspaceLayout? = nil, removed: WorkspaceLayout? = nil, changed: Bool
    ) {
        self.operation = operation
        self.layouts = layouts
        self.layout = layout
        self.removed = removed
        self.changed = changed
    }
}

public struct WorkspaceOperationError: LocalizedError, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case invalid
        case notFound
        case unavailable
    }

    public let kind: Kind
    public let message: String
    public let hint: String?

    public init(_ kind: Kind, _ message: String, hint: String? = nil) {
        self.kind = kind
        self.message = message
        self.hint = hint
    }

    public var errorDescription: String? { message }
}

public enum WorkspaceOperationExecution {
    public static func workspace(matching query: String, in store: WorkspaceStore) throws
        -> WorkspaceLayout
    {
        guard !store.layouts.isEmpty else {
            throw WorkspaceOperationError(
                .unavailable, "no workspaces are saved",
                hint: "make one with `ed machines workspace new`")
        }
        let needle = query.lowercased()
        if let exact = store.layouts.first(where: { $0.name.lowercased() == needle }) {
            return exact
        }
        if let byID = store.layouts.first(where: { $0.id.uuidString.lowercased() == needle }) {
            return byID
        }
        let prefixed = store.layouts.filter { $0.name.lowercased().hasPrefix(needle) }
        if prefixed.count == 1, let only = prefixed.first { return only }
        if prefixed.count > 1 {
            throw WorkspaceOperationError(
                .notFound, "\(query) matches more than one workspace",
                hint: prefixed.map(\.name).joined(separator: ", "))
        }
        throw WorkspaceOperationError(
            .notFound, "no workspace called \(query)",
            hint: "known: " + store.layouts.map(\.name).joined(separator: ", "))
    }

    public static func workspace(id: UUID, in store: WorkspaceStore) throws -> WorkspaceLayout {
        guard let layout = store.layouts.first(where: { $0.id == id }) else {
            throw WorkspaceOperationError(.notFound, "the workspace no longer exists")
        }
        return layout
    }

    public static func pane(at index: Int, in layout: WorkspaceLayout) throws -> PaneNode {
        let panes = layout.root.panes
        guard index >= 1, index <= panes.count else {
            throw WorkspaceOperationError(
                .notFound, "there is no pane \(index) in \(layout.name)",
                hint: "it has \(panes.count), numbered from 1")
        }
        return panes[index - 1]
    }

    @discardableResult
    public static func perform(
        _ request: WorkspaceOperationRequest, in store: inout WorkspaceStore
    ) throws -> WorkspaceOperationResult {
        switch request {
        case .list:
            return result(.list, store: store, layout: store.current, changed: false)
        case let .create(layout):
            store.upsert(layout)
            return result(.create, store: store, layout: layout, changed: true)
        case let .use(workspaceID):
            let layout = try workspace(id: workspaceID, in: store)
            let changed = store.currentID != layout.id
            store.currentID = layout.id
            return result(.use, store: store, layout: layout, changed: changed)
        case let .rename(workspaceID, name):
            var layout = try workspace(id: workspaceID, in: store)
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw WorkspaceOperationError(.invalid, "a workspace needs a name")
            }
            let changed = layout.name != trimmed
            layout.name = trimmed
            try replace(layout, in: &store)
            return result(.rename, store: store, layout: layout, changed: changed)
        case let .remove(workspaceID):
            let layout = try workspace(id: workspaceID, in: store)
            store.remove(layout.id)
            return result(
                .remove, store: store, layout: store.current, removed: layout, changed: true)
        case let .split(workspaceID, paneID, side, target):
            var layout = try workspace(id: workspaceID, in: store)
            guard layout.root.pane(paneID) != nil else {
                throw WorkspaceOperationError(.notFound, "the workspace pane no longer exists")
            }
            layout.split(paneID: paneID, side: side, target: target)
            try replacePaneLayout(layout, in: &store)
            return result(.split, store: store, layout: layout, changed: true)
        case let .close(workspaceID, paneID):
            var layout = try workspace(id: workspaceID, in: store)
            guard layout.paneCount > 1 else {
                throw WorkspaceOperationError(
                    .invalid, "\(layout.name) has one pane left, and a workspace needs one",
                    hint: "remove the whole thing with `ed machines workspace rm`")
            }
            guard layout.root.pane(paneID) != nil else {
                throw WorkspaceOperationError(.notFound, "the workspace pane no longer exists")
            }
            layout.closePane(paneID)
            try replacePaneLayout(layout, in: &store)
            return result(.close, store: store, layout: layout, changed: true)
        case let .point(workspaceID, paneID, targets):
            var layout = try workspace(id: workspaceID, in: store)
            guard let pane = layout.root.pane(paneID) else {
                throw WorkspaceOperationError(.notFound, "the workspace pane no longer exists")
            }
            guard !targets.isEmpty else {
                throw WorkspaceOperationError(.invalid, "say which workspace tab to point")
            }
            let existing = Set(pane.tabs.map(\.id))
            guard targets.allSatisfy({ existing.contains($0.tabID) }) else {
                throw WorkspaceOperationError(.notFound, "the workspace tab no longer exists")
            }
            layout.root.updatePane(paneID) { node in
                for target in targets {
                    guard let index = node.tabs.firstIndex(where: { $0.id == target.tabID }) else {
                        continue
                    }
                    node.tabs[index].target = target.target
                }
            }
            try replacePaneLayout(layout, in: &store)
            return result(.point, store: store, layout: layout, changed: true)
        case let .equalize(workspaceID, splitID):
            var layout = try workspace(id: workspaceID, in: store)
            if let splitID {
                guard layout.root.split(splitID) != nil else {
                    throw WorkspaceOperationError(.notFound, "the workspace split no longer exists")
                }
                layout.root.updateSplit(splitID) { split in
                    split.ratios = Array(
                        repeating: 1.0 / Double(split.children.count),
                        count: split.children.count)
                }
            } else {
                layout.root.equalize()
            }
            try replacePaneLayout(layout, in: &store)
            return result(.equalize, store: store, layout: layout, changed: true)
        }
    }

    private static func replace(_ layout: WorkspaceLayout, in store: inout WorkspaceStore) throws {
        guard let index = store.layouts.firstIndex(where: { $0.id == layout.id }) else {
            throw WorkspaceOperationError(.notFound, "the workspace no longer exists")
        }
        store.layouts[index] = layout
    }

    private static func replacePaneLayout(
        _ layout: WorkspaceLayout, in store: inout WorkspaceStore
    ) throws {
        try replace(layout, in: &store)
        if store.currentID == nil { store.currentID = layout.id }
    }

    private static func result(
        _ operation: WorkspaceOperation, store: WorkspaceStore,
        layout: WorkspaceLayout? = nil, removed: WorkspaceLayout? = nil, changed: Bool
    ) -> WorkspaceOperationResult {
        WorkspaceOperationResult(
            operation: operation, layouts: store.layouts, layout: layout, removed: removed,
            changed: changed)
    }
}

extension LayoutNode {
    public func split(_ id: UUID) -> SplitNode? {
        switch self {
        case .pane:
            nil
        case let .split(split):
            if split.id == id {
                split
            } else {
                split.children.lazy.compactMap { $0.split(id) }.first
            }
        }
    }
}

struct MachineWorkspacePaneRequest: Codable, Sendable {
    enum Action: String, Codable, Sendable { case split, resize, equalize }
    let presentationID: UUID
    let terminal: MachineTerminalRequest
    let sequence: UInt64
    let baseline: WorkspaceLayout
    let paneID: UUID
    let tabID: UUID
    let action: Action
    let side: InsertSide?
    let distance: Double?
    let extent: Double?

    func apply(to store: inout WorkspaceStore) throws {
        guard sequence > 0, store.current == baseline, baseline.focused == paneID,
            let pane = baseline.root.pane(paneID), pane.selected == tabID,
            let tab = pane.tabs.first(where: { $0.id == tabID }), tab.target.screen == .terminal,
            baseline.paneCount <= 64
        else { throw MachineUIError.invalidRequest }
        switch action {
        case .split:
            guard let side, distance == nil, extent == nil, baseline.paneCount < 64 else {
                throw MachineUIError.invalidRequest
            }
            try WorkspaceOperationExecution.perform(
                .split(workspaceID: baseline.id, paneID: paneID, side: side, target: tab.target),
                in: &store)
        case .equalize:
            guard side == nil, distance == nil, extent == nil else {
                throw MachineUIError.invalidRequest
            }
            try WorkspaceOperationExecution.perform(.equalize(workspaceID: baseline.id), in: &store)
        case .resize:
            guard let side, let distance, let extent, distance.isFinite, extent.isFinite,
                distance > 0, distance <= 4_096, extent > 0, extent <= 32_768
            else { throw MachineUIError.invalidRequest }
            var layout = baseline
            guard layout.root.resizePane(paneID, side: side, distance: distance, extent: extent)
            else { throw MachineUIError.invalidRequest }
            store.upsert(layout)
        }
    }
}

extension LayoutNode {
    private func splitPath(to paneID: UUID) -> [(SplitNode, Int)]? {
        switch self {
        case let .pane(pane): return pane.id == paneID ? [] : nil
        case let .split(split):
            for (index, child) in split.children.enumerated() {
                if let path = child.splitPath(to: paneID) { return [(split, index)] + path }
            }
            return nil
        }
    }

    mutating func resizePane(_ paneID: UUID, side: InsertSide, distance: Double, extent: Double)
        -> Bool
    {
        guard let path = splitPath(to: paneID) else { return false }
        var childExtent = extent
        for (split, index) in path.reversed() where split.axis == side.axis {
            guard split.ratios.count == split.children.count,
                split.ratios.indices.contains(index), split.ratios[index].isFinite,
                split.ratios[index] > 0
            else { return false }
            let available = childExtent / split.ratios[index]
            let neighbor = side.isBefore ? index - 1 : index + 1
            if split.ratios.indices.contains(neighbor) {
                let change = distance / available
                guard change.isFinite, split.ratios[neighbor] - change >= 0.08,
                    split.ratios[index] + change <= 0.92
                else { return false }
                updateSplit(split.id) {
                    $0.ratios[index] += change
                    $0.ratios[neighbor] -= change
                }
                return true
            }
            childExtent = available + Double(split.children.count - 1) * 6
        }
        return false
    }
}
