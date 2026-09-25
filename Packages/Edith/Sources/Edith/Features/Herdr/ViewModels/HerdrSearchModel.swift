import EdithKit
import Foundation
import Observation

typealias HerdrSessionSearcher = @Sendable (AgentSearchRequest) async throws -> AgentSearchReply

struct HerdrSearchRow: Identifiable, Equatable {
    let agent: HerdrAgent
    let hit: AgentSearchHit?

    var id: String { agent.id }
    var title: String { agent.title }
    var snippet: String { hit?.snippet ?? "" }

    var project: String {
        let folder = (agent.cwd as NSString).lastPathComponent
        return folder.isEmpty ? agent.workspace : folder
    }

    var place: String {
        [project, agent.workspace].filter { !$0.isEmpty }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: " · ")
    }
}

enum HerdrSearchSectionState: Equatable {
    case searching
    case indexing(Int)
    case ready
    case failed(String)
}

struct HerdrSearchSection: Identifiable, Equatable {
    let id: String
    let name: String
    let isLocal: Bool
    let agents: [HerdrAgent]
    var state: HerdrSearchSectionState
    var rows: [HerdrSearchRow]
    var milliseconds: Int?
}

enum HerdrSearchBest: Equatable {
    case hidden
    case ranking
    case ready([HerdrSearchRow])
    case noMatch
}

@MainActor
@Observable
final class HerdrSearchModel {
    nonisolated static let debounce: Duration = .milliseconds(250)
    nonisolated static let jevDelay: Duration = .milliseconds(300)
    nonisolated static let followUpDelay: Duration = .milliseconds(120)
    nonisolated static let jevPerMachine = 8
    nonisolated static let concurrencyLimit = 4

    var query = ""
    private(set) var selectedID: String?
    private(set) var sections: [HerdrSearchSection] = []
    private(set) var best: HerdrSearchBest = .hidden
    private(set) var searchedQuery: String?

    @ObservationIgnored private let searcher: HerdrSessionSearcher
    @ObservationIgnored private let decider: @MainActor () -> JevDeciding?
    @ObservationIgnored private var serial = 0
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var jevTask: Task<Void, Never>?

    init(
        searcher: @escaping HerdrSessionSearcher = { try await AgentSearchClient().search($0) },
        decider: @escaping @MainActor () -> JevDeciding? = { AgentJevDecider.configured() }
    ) {
        self.searcher = searcher
        self.decider = decider
    }

    var bestRows: [HerdrSearchRow] {
        if case .ready(let rows) = best { return rows }
        return []
    }

    var rows: [HerdrSearchRow] {
        HerdrSearchPlan.flatten(best: bestRows, sections: sections)
    }

    var isBusy: Bool {
        best == .ranking
            || sections.contains { section in
                if case .searching = section.state { return true }
                if case .indexing = section.state { return true }
                return false
            }
    }

    var usesJev: Bool { best != .hidden }

    var machineProgress: (done: Int, total: Int) {
        HerdrSearchPlan.progress(sections)
    }

    func visibleRows(in section: HerdrSearchSection) -> [HerdrSearchRow] {
        HerdrSearchPlan.visible(section, excluding: bestRows)
    }

    func queryChanged(agents: [HerdrAgent], hosts: [HerdrHostSnapshot]) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.search(agents: agents, hosts: hosts)
        }
    }

    func submit(agents: [HerdrAgent], hosts: [HerdrHostSnapshot]) -> HerdrAgent? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != searchedQuery {
            search(agents: agents, hosts: hosts)
            return nil
        }
        return selectedRow?.agent
    }

    func search(agents: [HerdrAgent], hosts: [HerdrHostSnapshot]) {
        debounceTask?.cancel()
        searchTask?.cancel()
        jevTask?.cancel()
        serial += 1
        let serial = serial
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchedQuery = query
        best = .hidden
        sections = HerdrSearchPlan.sections(agents: agents, hosts: hosts, query: query)
        selectedID = rows.first?.id
        let searcher = searcher
        let requests = HerdrSearchPlan.requests(sections: sections, query: query)
        searchTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                var waiting = requests[...]
                var running = 0
                while !waiting.isEmpty || running > 0 {
                    while running < Self.concurrencyLimit, let request = waiting.popFirst() {
                        group.addTask {
                            await Self.stream(
                                request, serial: serial, searcher: searcher, into: self)
                        }
                        running += 1
                    }
                    await group.next()
                    running -= 1
                }
            }
        }
    }

    nonisolated static func stream(
        _ request: AgentSearchRequest, serial: Int, searcher: HerdrSessionSearcher,
        into model: HerdrSearchModel?
    ) async {
        while !Task.isCancelled {
            let reply: AgentSearchReply
            do {
                reply = try await searcher(request)
            } catch {
                reply = AgentSearchReply(
                    machineID: request.machineID, error: error.localizedDescription)
            }
            guard !Task.isCancelled, await model?.receive(reply, serial: serial) == true else {
                return
            }
            try? await Task.sleep(for: followUpDelay)
        }
    }

    @discardableResult
    func receive(_ reply: AgentSearchReply, serial: Int) -> Bool {
        guard serial == self.serial,
            let index = sections.firstIndex(where: { $0.id == reply.machineID })
        else { return false }
        if let error = reply.error {
            sections[index].state = .failed(error)
        } else {
            sections[index].rows = HerdrSearchPlan.rows(
                for: sections[index].agents, hits: reply.hits, query: searchedQuery ?? "")
            sections[index].state = reply.pending > 0 ? .indexing(reply.pending) : .ready
            sections[index].milliseconds = reply.milliseconds
        }
        keepSelection()
        scheduleJev()
        return reply.error == nil && reply.pending > 0
    }

    func move(_ delta: Int) {
        let rows = rows
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == selectedID } ?? -1
        let next = current < 0 ? (delta > 0 ? 0 : rows.count - 1) : current + delta
        selectedID = rows[(next + rows.count) % rows.count].id
    }

    func select(_ row: HerdrSearchRow) {
        selectedID = row.id
    }

    var selectedRow: HerdrSearchRow? {
        rows.first { $0.id == selectedID } ?? rows.first
    }

    func cancel() {
        debounceTask?.cancel()
        searchTask?.cancel()
        jevTask?.cancel()
        serial += 1
    }

    private func keepSelection() {
        let rows = rows
        if !rows.contains(where: { $0.id == selectedID }) { selectedID = rows.first?.id }
    }

    private func scheduleJev() {
        jevTask?.cancel()
        let query = searchedQuery ?? ""
        guard !query.isEmpty, let decider = decider() else {
            best = .hidden
            return
        }
        let candidates = HerdrSearchPlan.jevCandidates(sections)
        guard candidates.count >= 2 else {
            best = sections.contains { $0.state == .searching } ? .ranking : .hidden
            return
        }
        if case .ready = best {} else { best = .ranking }
        let serial = serial
        let options = HerdrSearchPlan.jevOptions(candidates)
        jevTask = Task { [weak self] in
            try? await Task.sleep(for: Self.jevDelay)
            guard !Task.isCancelled else { return }
            let picks = try? await AgentSearchJev.rank(query, candidates: options, using: decider)
            guard !Task.isCancelled, let self, serial == self.serial else { return }
            self.best = HerdrSearchPlan.best(picks, from: candidates)
            self.keepSelection()
        }
    }
}

enum HerdrSearchPlan {
    static func sections(
        agents: [HerdrAgent], hosts: [HerdrHostSnapshot], query: String
    ) -> [HerdrSearchSection] {
        let open = agents.filter { !$0.isTerminal }
        let grouped = Dictionary(grouping: open, by: \.machineID)
        let listed = hosts.map(\.id)
        let extra = grouped.keys.filter { !listed.contains($0) }.sorted()
        return (listed + extra).compactMap { machineID in
            guard let members = grouped[machineID], let first = members.first else { return nil }
            let name = hosts.first { $0.id == machineID }?.name ?? first.machineName
            return HerdrSearchSection(
                id: machineID, name: name, isLocal: first.machineIsLocal, agents: members,
                state: .searching,
                rows: query.isEmpty ? members.map { HerdrSearchRow(agent: $0, hit: nil) } : [])
        }
    }

    static func requests(sections: [HerdrSearchSection], query: String)
        -> [AgentSearchRequest]
    {
        sections.map { section in
            AgentSearchRequest(
                query: query, machineID: section.id,
                targets: section.agents.map(AgentSearchTarget.init(agent:)))
        }
    }

    static func rows(for agents: [HerdrAgent], hits: [AgentSearchHit], query: String)
        -> [HerdrSearchRow]
    {
        let byID = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var rows: [HerdrSearchRow] = []
        for hit in hits where seen.insert(hit.id).inserted {
            guard let agent = byID[hit.id] else { continue }
            rows.append(HerdrSearchRow(agent: agent, hit: hit))
        }
        guard query.isEmpty else { return rows }
        let rest = agents.filter { !seen.contains($0.id) }
        return rows + rest.map { HerdrSearchRow(agent: $0, hit: nil) }
    }

    static func progress(_ sections: [HerdrSearchSection]) -> (done: Int, total: Int) {
        var done = 0
        for section in sections {
            switch section.state {
            case .ready, .failed: done += 1
            case .searching, .indexing: break
            }
        }
        return (done, sections.count)
    }

    static func flatten(best: [HerdrSearchRow], sections: [HerdrSearchSection])
        -> [HerdrSearchRow]
    {
        best + sections.flatMap { visible($0, excluding: best) }
    }

    static func visible(_ section: HerdrSearchSection, excluding best: [HerdrSearchRow])
        -> [HerdrSearchRow]
    {
        let chosen = Set(best.map(\.id))
        return section.rows.filter { !chosen.contains($0.id) }
    }

    static func jevCandidates(_ sections: [HerdrSearchSection]) -> [HerdrSearchRow] {
        var picked: [HerdrSearchRow] = []
        var seen = Set<String>()
        for depth in 0..<HerdrSearchModel.jevPerMachine {
            for section in sections where depth < section.rows.count {
                let row = section.rows[depth]
                guard seen.insert(row.id).inserted else { continue }
                picked.append(row)
            }
        }
        return Array(picked.prefix(AgentSearchJev.maximumCandidates))
    }

    static func jevOptions(_ rows: [HerdrSearchRow]) -> [AgentSearchCandidate] {
        rows.map { row in
            AgentSearchCandidate(
                id: row.id,
                meaning: AgentSearchJev.meaning(
                    kind: row.agent.kind, project: row.project, branch: nil,
                    machine: row.agent.machineName, title: row.title,
                    summary: row.hit?.summary ?? row.agent.workspace))
        }
    }

    static func best(_ picks: [String]?, from candidates: [HerdrSearchRow]) -> HerdrSearchBest {
        guard let picks else { return .hidden }
        let lookup = Dictionary(
            candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = picks.compactMap { lookup[$0] }
        return rows.isEmpty ? .noMatch : .ready(rows)
    }
}
