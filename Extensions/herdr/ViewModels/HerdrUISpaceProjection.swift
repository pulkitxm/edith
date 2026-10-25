import EdithExtensionSupport
import Foundation

struct HerdrUISpaceTab: Codable, Equatable {
    let id: UUID
    let title: String
    var layout: WorkspaceLayout
    let agents: [UUID: String]
    let views: [String: HerdrAgentView]
}

struct HerdrUISpace: Codable, Equatable {
    let token: UUID
    let id: String
    let title: String
    let contexts: [HerdrSpaceTerminalContext]
    var selected: UUID?
    var tabs: [HerdrUISpaceTab]

    func validate() throws {
        guard id.utf8.count <= 4096, title.utf8.count <= 4096, contexts.count <= 4096,
            tabs.count <= 64, Set(tabs.map(\.id)).count == tabs.count,
            selected == nil || tabs.contains(where: { $0.id == selected })
        else { throw ExtensionPeerError.invalidRequest }
        var agents = Set<String>()
        var placeholders = Set<UUID>()
        var nodes = Set<UUID>()
        for tab in tabs {
            guard tab.title.utf8.count <= 4096, tab.layout.name.utf8.count <= 4096,
                try tab.layout.root.validateSpace(depth: 0, nodes: &nodes),
                tab.layout.paneCount <= 32,
                tab.layout.root.panes.contains(where: { $0.id == tab.layout.focused }),
                tab.layout.maximized == nil
                    || tab.layout.root.panes.contains(where: { $0.id == tab.layout.maximized }),
                Set(tab.views.keys) == Set(tab.agents.values)
            else { throw ExtensionPeerError.invalidRequest }
            var local = Set<UUID>()
            for pane in tab.layout.root.panes {
                guard !pane.tabs.isEmpty, pane.tabs.count <= 32,
                    pane.tabs.contains(where: { $0.id == pane.selected })
                else { throw ExtensionPeerError.invalidRequest }
                for placeholder in pane.tabs {
                    guard placeholder.target.screen == .terminal,
                        (placeholder.target.argument?.utf8.count ?? 0) <= 4096,
                        !(placeholder.target.argument?.utf8.contains(0) ?? false),
                        (placeholder.titleOverride?.utf8.count ?? 0) <= 4096,
                        placeholders.insert(placeholder.id).inserted
                    else { throw ExtensionPeerError.invalidRequest }
                    local.insert(placeholder.id)
                }
            }
            guard Set(tab.agents.keys).isSubset(of: local),
                tab.agents.values.allSatisfy({ $0.utf8.count <= 512 && agents.insert($0).inserted })
            else { throw ExtensionPeerError.invalidRequest }
        }
    }
}

extension LayoutNode {
    fileprivate func validateSpace(depth: Int, nodes: inout Set<UUID>) throws -> Bool {
        guard depth <= 16, nodes.insert(id).inserted else { return false }
        switch self {
        case .pane: return true
        case .split(let split):
            guard (2...32).contains(split.children.count),
                split.ratios.count == split.children.count,
                split.ratios.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 1 }),
                abs(split.ratios.reduce(0, +) - 1) < 0.000001
            else { return false }
            for child in split.children
            where try !child.validateSpace(depth: depth + 1, nodes: &nodes) { return false }
            return true
        }
    }
}

struct HerdrUISpaceMutation: Codable {
    let baseline: HerdrUISpace
    let space: HerdrUISpace
}
