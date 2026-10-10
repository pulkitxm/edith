import EdithExtensionSupport
import Foundation

struct HerdrSpaceInfo: Codable, Equatable {
    let id: String
    let title: String
    let tabs: Int
    let panes: Int
}

struct HerdrUIPresentation: Codable {
    let version: Int
    let owner: String
    let location: String
    let target: String
    let token: UUID
    let title: String
    let width: Int
    let height: Int
    let minimumWidth: Int
    let minimumHeight: Int
    let presented: Bool
}

@MainActor final class HerdrSpaceSessions {
    struct Entry {
        let token: UUID
        let kind: String
        let id: String
        let title: String
        let model: HerdrSpaceWindowModel?
        var admitted = false
    }
    private let store: HerdrStore
    private var entries: [UUID: Entry] = [:]
    private var focused: UUID?
    private var stopped = false
    private var retired: Set<UUID> = []
    private var retiredOrder: [UUID] = []

    init(store: HerdrStore) { self.store = store }

    func present(_ object: [String: Any]) throws -> HerdrUIPresentation {
        guard !stopped, let kind = object["kind"] as? String, ["agent", "space"].contains(kind),
            let id = object["id"] as? String, id.utf8.count <= 4096,
            Set(object.keys).isSubset(of: ["kind", "id", "agentIDs"])
        else { throw ExtensionPeerError.invalidRequest }
        if let supplied = object["agentIDs"] {
            guard kind == "space", let ids = supplied as? [String], !ids.isEmpty, ids.count <= 4096,
                Set(ids).count == ids.count,
                ids.allSatisfy({ $0.utf8.count <= 512 && !$0.utf8.contains(0) })
            else { throw ExtensionPeerError.invalidRequest }
        }
        if let entry = entries.values.first(where: { $0.kind == kind && $0.id == id }) {
            return presentation(entry)
        }
        guard entries.count < 64 else { throw ExtensionPeerError.unavailable }
        let title: String
        let model: HerdrSpaceWindowModel?
        if kind == "space" {
            guard let original = HerdrAgentSpace.group(store.agents).first(where: { $0.id == id })
            else {
                throw ExtensionPeerError.invalidRequest
            }
            var agents = original.agents
            if let supplied = object["agentIDs"] {
                guard let ids = supplied as? [String], !ids.isEmpty, ids.count <= 4096,
                    Set(ids).count == ids.count,
                    Set(ids).isSubset(of: Set(agents.map(\.id)))
                else { throw ExtensionPeerError.invalidRequest }
                let lookup = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
                agents = ids.compactMap { lookup[$0] }
            }
            for agent in agents {
                for entry in Array(entries.values)
                where entry.kind == "agent" && entry.id == agent.id { try close(entry.token) }
            }
            title = original.title
            model = HerdrSpaceWindowModel(
                space: .init(id: id, title: title, agents: agents), store: store)
        } else {
            guard object["agentIDs"] == nil,
                let agent = (store.agents + store.hosts.map { HerdrMachineTerminal.agent(for: $0) })
                    .first(where: { $0.id == id })
            else { throw ExtensionPeerError.invalidRequest }
            removeAgent(id)
            title = "\(agent.title) · \(agent.machineName)"
            store.close(id, rememberingPlacement: false)
            _ = store.detachedTab(for: agent)
            model = nil
        }
        let entry = Entry(token: UUID(), kind: kind, id: id, title: title, model: model)
        entries[entry.token] = entry
        return presentation(entry)
    }

    func admit(_ token: UUID) throws {
        guard !stopped, entries[token] != nil else { throw ExtensionPeerError.invalidRequest }
        entries[token]?.admitted = true
    }

    func focus(_ token: UUID, key: Bool) throws {
        guard !stopped, entries[token]?.admitted == true else {
            throw ExtensionPeerError.invalidRequest
        }
        if key { focused = token } else if focused == token { focused = nil }
    }

    func close(_ token: UUID) throws {
        if retired.contains(token) { return }
        guard let entry = entries.removeValue(forKey: token) else {
            throw ExtensionPeerError.invalidRequest
        }
        retired.insert(token)
        retiredOrder.append(token)
        if retiredOrder.count > 512 { retired.remove(retiredOrder.removeFirst()) }
        entry.model?.stopAll()
        if entry.kind == "agent" { store.reattach(entry.id) }
        if focused == token { focused = nil }
    }

    func listed() -> [HerdrSpaceInfo] {
        entries.values.filter { $0.admitted && $0.model != nil }.map(info)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func openTerminal(_ token: String?) -> HerdrSpaceInfo? {
        guard let entry = resolve(token), let model = entry.model, model.tabs.count < 64 else {
            return nil
        }
        model.addTerminal()
        return info(entry)
    }

    func split(_ token: String?, side: InsertSide) -> HerdrSpaceInfo? {
        guard let entry = resolve(token), let model = entry.model,
            (model.selectedTab?.paneCount ?? 0) < 32
        else { return nil }
        model.split(side)
        return info(entry)
    }

    func missing(_ token: String?) -> String {
        if listed().isEmpty { return "no space window is open" }
        if let token, !token.isEmpty { return "no space window matches \(token)" }
        return "more than one space window is open"
    }

    var presentations: [HerdrUIPresentation] {
        entries.values.map(presentation).sorted { $0.token.uuidString < $1.token.uuidString }
    }
    var uiSpaces: [HerdrUISpace] {
        entries.values.compactMap { entry in entry.model?.uiState(token: entry.token) }.sorted {
            $0.id < $1.id
        }
    }
    var openedAgents: [HerdrAgent] {
        entries.values.compactMap(\.model).flatMap(\.tabs).compactMap { $0.agentTab?.agent }
    }

    func setAgentView(_ view: HerdrAgentView, token: UUID) throws {
        guard !stopped, let entry = entries[token], entry.kind == "agent", entry.admitted,
            store.detachedTab(id: entry.id) != nil
        else { throw ExtensionPeerError.invalidRequest }
        store.setView(view, for: entry.id)
    }

    func apply(_ mutation: HerdrUISpaceMutation) throws {
        guard !stopped, let entry = entries[mutation.space.token], let model = entry.model,
            mutation.baseline == model.uiState(token: entry.token),
            mutation.space.id == entry.id, mutation.space.title == model.spaceTitle,
            mutation.space.contexts == model.contexts
        else {
            throw ExtensionPeerError.rejected(
                "The space changed in another view. Refresh and try again.")
        }
        try mutation.space.validate()
        let baseline = mutation.baseline
        let targets = Set(
            baseline.contexts.map(\.target)
                + baseline.tabs.flatMap { $0.layout.root.panes.flatMap(\.tabs).map(\.target) })
        let agents = Set(baseline.tabs.flatMap { $0.agents.values })
        guard
            mutation.space.tabs.flatMap({ $0.layout.root.panes.flatMap(\.tabs) }).allSatisfy({
                targets.contains($0.target)
            }),
            Set(mutation.space.tabs.flatMap { $0.agents.values }).isSubset(of: agents)
        else { throw ExtensionPeerError.invalidRequest }
        model.adopt(mutation.space, store: store)
    }

    func removeAgent(_ id: String) {
        for entry in Array(entries.values) {
            if entry.kind == "agent", entry.id == id {
                try? close(entry.token)
            } else if let model = entry.model {
                model.removeAgent(id)
                if model.tabs.isEmpty { try? close(entry.token) }
            }
        }
    }

    func agentTab(_ id: String) -> HerdrOpenTab? {
        entries.values.compactMap(\.model).flatMap(\.tabs).compactMap(\.agentTab).first {
            $0.id == id
        }
    }
    func holds(_ id: String) -> Bool { agentTab(id) != nil }
    var holders: [TerminalSessionHolder] {
        entries.values.compactMap(\.model).flatMap(\.tabs).flatMap(\.holders)
    }
    func stopAll() {
        stopped = true
        for entry in entries.values { entry.model?.stopAll() }
        entries.removeAll()
        focused = nil
    }

    private func resolve(_ raw: String?) -> Entry? {
        guard !stopped else { return nil }
        let open = entries.values.filter { $0.admitted && $0.model != nil }
        let token = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !token.isEmpty {
            if let exact = open.first(where: { $0.id == token }) { return exact }
            let named = open.filter { $0.title.caseInsensitiveCompare(token) == .orderedSame }
            return named.count == 1 ? named[0] : nil
        }
        if open.count == 1 { return open.first }
        return open.first { $0.token == focused }
    }

    private func info(_ entry: Entry) -> HerdrSpaceInfo {
        .init(
            id: entry.id, title: entry.title, tabs: entry.model?.tabs.count ?? 0,
            panes: entry.model?.tabs.reduce(0) { $0 + $1.paneCount } ?? 0)
    }
    private func presentation(_ entry: Entry) -> HerdrUIPresentation {
        let space = entry.kind == "space"
        return .init(
            version: 1, owner: "herdr", location: "herdr." + entry.kind,
            target: entry.id, token: entry.token, title: entry.title,
            width: space ? 1180 : 1000, height: space ? 760 : 640,
            minimumWidth: space ? 760 : 560, minimumHeight: space ? 460 : 360,
            presented: entry.admitted)
    }
}
