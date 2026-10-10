import EdithExtensionSupport
import Foundation

struct HerdrUIPanelTerminal: Codable {
    let id: String
    let machineID: String
    let machineName: String
    let isLocal: Bool
    let session: String
    let cwd: String?
    let pane: String?
    let process: HerdrPaneProcess?
    let failure: String?
    let adopted: Bool
    let seen: Bool
}

struct HerdrUIPanelState: Codable {
    let panels: [String: HerdrTerminalPanel]
    let focused: String?
    let maximized: Bool
    let height: Double
    let terminals: [HerdrUIPanelTerminal]

    func validate() throws {
        let ids = Set(terminals.map(\.id))
        guard panels.count <= 65, terminals.count <= 256, ids.count == terminals.count,
            height.isFinite, (120...2048).contains(height),
            focused == nil || panels[focused!] != nil
        else { throw ExtensionPeerError.invalidRequest }
        var placed = Set<String>()
        for panel in panels.values {
            guard panel.terminalIDs.count <= 64,
                Set(panel.terminalIDs).isSubset(of: ids),
                placed.isDisjoint(with: panel.terminalIDs),
                panel.selectedID == nil || panel.terminalIDs.contains(panel.selectedID!)
            else { throw ExtensionPeerError.invalidRequest }
            placed.formUnion(panel.terminalIDs)
        }
        guard placed == ids else { throw ExtensionPeerError.invalidRequest }
        for terminal in terminals {
            guard UUID(uuidString: terminal.id) != nil, !terminal.session.isEmpty,
                [
                    terminal.machineID, terminal.machineName, terminal.session, terminal.cwd ?? "",
                    terminal.pane ?? "",
                ].allSatisfy({ $0.utf8.count <= 4096 && !$0.utf8.contains(0) })
            else { throw ExtensionPeerError.invalidRequest }
        }
    }
}

@MainActor enum HerdrUIPanelActions {
    static func execute(_ object: [String: Any], store: HerdrStore) async throws {
        guard let operation = object["operation"] as? String else {
            throw ExtensionPeerError.invalidRequest
        }
        let panels = store.terminalPanels
        let owners = Set([HerdrStore.boardID] + store.tabs.map(\.id) + Array(panels.panels.keys))
        func owner() throws -> String {
            guard let id = object["owner"] as? String, owners.contains(id) else {
                throw ExtensionPeerError.invalidRequest
            }
            return id
        }
        func terminal() throws -> String {
            guard let id = object["terminalID"] as? String, panels.terminals[id] != nil else {
                throw ExtensionPeerError.invalidRequest
            }
            return id
        }
        func keys(_ fields: Set<String>) throws {
            guard Set(object.keys) == fields.union(["operation"]) else {
                throw ExtensionPeerError.invalidRequest
            }
        }
        switch operation {
        case "new", "show":
            try keys(["owner", "machineID", "cwd"])
            let id = try owner()
            guard id == HerdrStore.boardID || store.tab(id) != nil,
                let machineID = object["machineID"] as? String,
                let cwd = object["cwd"] as? String,
                let origin = store.terminalOrigins(for: id).first(where: {
                    $0.host.machineID == machineID && ($0.cwd ?? HerdrTerminalOrigin.home) == cwd
                }), panels.terminals.count < 256
            else { throw ExtensionPeerError.invalidRequest }
            if operation == "new" {
                panels.newTerminal(in: id, host: origin.host, cwd: origin.cwd)
            } else {
                panels.show(id, host: origin.host, cwd: origin.cwd)
            }
        case "hide", "focus":
            try keys(["owner"])
            if operation == "hide" { panels.hide(try owner()) } else { panels.focus(try owner()) }
        case "releaseFocus":
            try keys([])
            panels.releaseFocus()
        case "select":
            try keys(["owner", "terminalID"])
            let id = try owner()
            let selected = try terminal()
            guard panels.panels[id]?.terminalIDs.contains(selected) == true else {
                throw ExtensionPeerError.invalidRequest
            }
            panels.select(selected, in: id)
        case "close", "retry":
            try keys(["terminalID"])
            let id = try terminal()
            if operation == "close" { panels.close(id) } else { panels.retry(id) }
        case "closeAll":
            try keys(["owners"])
            guard let ids = object["owners"] as? [String], ids.count <= 65,
                Set(ids).isSubset(of: owners)
            else { throw ExtensionPeerError.invalidRequest }
            panels.closeAll(owners: ids)
        case "refresh":
            if object["owner"] != nil {
                try keys(["owner"]); await panels.refresh(try owner())
            } else {
                try keys(["ids"])
                guard let ids = object["ids"] as? [String], ids.count <= 256,
                    Set(ids).isSubset(of: Set(panels.terminals.keys))
                else { throw ExtensionPeerError.invalidRequest }
                for (owner, panel) in panels.panels
                where !Set(panel.terminalIDs).isDisjoint(with: ids) { await panels.refresh(owner) }
            }
        case "maximize":
            try keys(["value"])
            guard let value = object["value"] as? NSNumber,
                CFGetTypeID(value) == CFBooleanGetTypeID()
            else { throw ExtensionPeerError.invalidRequest }
            panels.maximized = value.boolValue
        case "height":
            try keys(["value"])
            guard let value = object["value"] as? NSNumber,
                CFGetTypeID(value) != CFBooleanGetTypeID(),
                value.doubleValue.isFinite, (120...2048).contains(value.doubleValue)
            else { throw ExtensionPeerError.invalidRequest }
            panels.height = value.doubleValue
        default: throw ExtensionPeerError.invalidRequest
        }
        try Task.checkCancellation()
    }
}
