import EdithKit
import Foundation
import Observation

typealias HerdrSessionSearcher = @Sendable (AgentSearchRequest) async throws -> AgentSearchReply

struct HerdrSearchRow: Identifiable, Equatable {
    let id: String
    let hostID: String
    let hostName: String
    let hit: AgentSearchHit?
    let agent: HerdrAgent?

    var title: String { hit?.title ?? agent?.title ?? "" }
    var kind: String { agent?.kind ?? hit?.kind.displayName ?? "" }
    var snippet: String { hit?.snippet ?? "" }

    var project: String {
        if let hit { return hit.project }
        guard let agent else { return "" }
        let folder = (agent.cwd as NSString).lastPathComponent
        return folder.isEmpty ? agent.workspace : folder
    }

    var place: String {
        [project, hit?.branch ?? agent?.workspace ?? ""].filter { !$0.isEmpty }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: " · ")
    }
}

enum HerdrSearchSectionState: Equatable {
    case searching
    case indexing(Int)
    case ready
    case failed(String)
    case offline
}

struct HerdrSearchSection: Identifiable, Equatable {
    let id: String
    let name: String
    let isLocal: Bool
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

enum HerdrSearchAction: Equatable {
    case open(HerdrAgent)
    case resume(AgentSearchHit, HerdrHostSnapshot)
}

@MainActor
@Observable
final class HerdrSearchModel {
    nonisolated static let debounce: Duration = .milliseconds(250)
    nonisolated static let jevDelay: Duration = .milliseconds(300)
    nonisolated static let followUpDelay: Duration = .milliseconds(120)
    nonisolated static let perMachineLimit = 12
    nonisolated static let liveLimit = 6
    nonisolated static let jevPerMachine = 8
    nonisolated static let concurrencyLimit = 4

    var query = ""
    private(set) var selectedID: String?
    private(set) var sections: [HerdrSearchSection] = []
    private(set) var best: HerdrSearchBest = .hidden
    private(set) var searchedQuery: String?
    var resuming = false
    var errorMessage: String?

    @ObservationIgnored private let searcher: HerdrSessionSearcher
    @ObservationIgnored private let decider: @MainActor () -> JevDeciding?
    @ObservationIgnored private var serial = 0
    @ObservationIgnored private var hosts: [HerdrHostSnapshot] = []
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

    func visibleRows(in section: HerdrSearchSection) -> [HerdrSearchRow] {
        HerdrSearchPlan.visible(section, excluding: bestRows)
    }

    func queryChanged(hosts: [HerdrHostSnapshot]) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.search(hosts: hosts)
        }
    }

    func submit(hosts: [HerdrHostSnapshot]) -> HerdrSearchAction? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != searchedQuery {
            search(hosts: hosts)
            return nil
        }
        return selectedRow.flatMap(action(for:))
    }

    func search(hosts: [HerdrHostSnapshot]) {
        debounceTask?.cancel()
        searchTask?.cancel()
        jevTask?.cancel()
        serial += 1
        let serial = serial
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let targets = hosts.isEmpty ? [HerdrHostSnapshot.local(herdrPresent: false)] : hosts
        self.hosts = targets
        searchedQuery = query
        errorMessage = nil
        best = .hidden
        sections = HerdrSearchPlan.sections(for: targets, query: query)
        selectedID = rows.first?.id
        let searcher = searcher
        let reachable = HerdrSearchPlan.reachable(targets)
        searchTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                var waiting = reachable[...]
                var running = 0
                while !waiting.isEmpty || running > 0 {
                    while running < Self.concurrencyLimit, let host = waiting.popFirst() {
                        group.addTask {
                            await Self.stream(
                                host: host, query: query, serial: serial, searcher: searcher,
                                into: self)
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
        host: HerdrHostSnapshot, query: String, serial: Int, searcher: HerdrSessionSearcher,
        into model: HerdrSearchModel?
    ) async {
        let request = AgentSearchRequest(query: query, machineID: host.id, limit: perMachineLimit)
        while !Task.isCancelled {
            let reply: AgentSearchReply
            do {
                reply = try await searcher(request)
            } catch {
                reply = AgentSearchReply(machineID: host.id, error: error.localizedDescription)
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
            let index = sections.firstIndex(where: { $0.id == reply.machineID }),
            let host = hosts.first(where: { $0.id == reply.machineID })
        else { return false }
        if let error = reply.error {
            sections[index].state = .failed(error)
        } else {
            sections[index].rows = HerdrSearchPlan.rows(
                for: host, hits: reply.hits, query: searchedQuery ?? "")
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

    func action(for row: HerdrSearchRow) -> HerdrSearchAction? {
        if let agent = row.agent { return .open(agent) }
        guard let hit = row.hit, let host = hosts.first(where: { $0.id == row.hostID }) else {
            return nil
        }
        return .resume(hit, host)
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
    static func sections(for hosts: [HerdrHostSnapshot], query: String) -> [HerdrSearchSection] {
        hosts.map { host in
            HerdrSearchSection(
                id: host.id, name: host.name, isLocal: host.isLocal,
                state: host.reachable ? .searching : .offline,
                rows: rows(for: host, hits: [], query: query))
        }
    }

    static func reachable(_ hosts: [HerdrHostSnapshot]) -> [HerdrHostSnapshot] {
        hosts.filter(\.reachable)
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
                    kind: row.kind, project: row.project, branch: row.hit?.branch,
                    machine: row.hostName, title: row.title,
                    summary: row.hit?.summary ?? row.agent?.workspace ?? ""))
        }
    }

    static func best(_ picks: [String]?, from candidates: [HerdrSearchRow]) -> HerdrSearchBest {
        guard let picks else { return .hidden }
        let lookup = Dictionary(
            candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = picks.compactMap { lookup[$0] }
        return rows.isEmpty ? .noMatch : .ready(rows)
    }

    static func rows(for host: HerdrHostSnapshot, hits: [AgentSearchHit], query: String)
        -> [HerdrSearchRow]
    {
        let live = host.agents.filter { !$0.isTerminal }
        var linked = Set<String>()
        var found: [HerdrSearchRow] = []
        for hit in hits {
            let agent = link(hit, live: live, taken: linked)
            if let agent { linked.insert(agent.id) }
            found.append(
                HerdrSearchRow(
                    id: hit.id, hostID: host.id, hostName: host.name, hit: hit, agent: agent))
        }
        let terms = AgentSearchTerms.terms(query)
        let matching = live.filter { agent in
            !linked.contains(agent.id)
                && AgentSearchTerms.covers(
                    [agent.title, agent.workspace, agent.cwd, agent.kind].joined(separator: " "),
                    all: terms)
        }
        let liveRows = matching.prefix(HerdrSearchModel.liveLimit).map { agent in
            HerdrSearchRow(
                id: agent.id, hostID: host.id, hostName: host.name, hit: nil, agent: agent)
        }
        return liveRows + found
    }

    static func link(_ hit: AgentSearchHit, live: [HerdrAgent], taken: Set<String>)
        -> HerdrAgent?
    {
        let place = standardized(hit.cwd)
        guard !place.isEmpty else { return nil }
        let matching = live.filter {
            AgentTranscriptKind(herdrKind: $0.kind) == hit.kind && standardized($0.cwd) == place
        }
        .sorted { $0.id < $1.id }
        guard matching.indices.contains(hit.placeRank) else { return nil }
        let agent = matching[hit.placeRank]
        return taken.contains(agent.id) ? nil : agent
    }

    static func standardized(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}
