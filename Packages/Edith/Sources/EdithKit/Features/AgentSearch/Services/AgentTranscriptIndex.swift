import Foundation

public struct AgentTranscriptRoots: Sendable, Equatable {
    public var claude: [URL]
    public var codex: [URL]
    public var pi: [URL]
    public var codexTitles: URL?

    public init(claude: [URL], codex: [URL], pi: [URL], codexTitles: URL?) {
        self.claude = claude
        self.codex = codex
        self.pi = pi
        self.codexTitles = codexTitles
    }

    public static func home(_ home: URL) -> AgentTranscriptRoots {
        AgentTranscriptRoots(
            claude: [home.appendingPathComponent(".claude/projects")],
            codex: [
                home.appendingPathComponent(".codex/sessions"),
                home.appendingPathComponent(".codex/archived_sessions"),
            ],
            pi: [home.appendingPathComponent(".pi/agent/sessions")],
            codexTitles: home.appendingPathComponent(".codex/session_index.jsonl"))
    }
}

public actor AgentTranscriptIndex {
    public static let shared = AgentTranscriptIndex(
        roots: .home(FileManager.default.homeDirectoryForCurrentUser),
        store: DataRoot.caches.appendingPathComponent("agent-search/transcripts-v2.json"))

    static let saveInterval: TimeInterval = 15

    struct Candidate {
        let url: URL
        let kind: AgentTranscriptKind
        let size: UInt64
        let modified: Double
    }

    private struct CachedDocument {
        let offset: UInt64
        let title: String
        let document: AgentSearchDocument
    }

    let roots: AgentTranscriptRoots
    let store: URL?
    let idleEviction: Duration
    private var digests: [String: AgentTranscriptDigest] = [:]
    private var documents: [String: CachedDocument] = [:]
    private var corpus: (version: Int, corpus: AgentSearchCorpus)?
    private var version = 0
    private var codexTitles: [String: String] = [:]
    private var codexTitlesModified: Double = 0
    private var loaded = false
    private var dirty = false
    private var lastSave = Date.distantPast
    private var evictionTask: Task<Void, Never>?

    public init(roots: AgentTranscriptRoots, store: URL?, idleEviction: Duration = .seconds(600)) {
        self.roots = roots
        self.store = store
        self.idleEviction = idleEviction
    }

    public func search(_ request: AgentSearchRequest, now: Date = Date()) -> AgentSearchReply {
        let started = Date()
        let pending = refresh(budget: request.budget)
        let entries = Self.unique(digests.values)
        let query = AgentSearchTerms.terms(request.query)
        let limit = max(1, request.limit)
        let picks: [(AgentTranscriptDigest, Double)]
        if query.isEmpty {
            picks = entries.sorted { ($0.lastActivity ?? 0) > ($1.lastActivity ?? 0) }
                .prefix(limit).map { ($0, 0) }
        } else {
            let ranked = AgentSearchRanker.rank(
                query, in: corpus(for: entries), now: now.timeIntervalSince1970)
            picks = ranked.prefix(limit).map { (entries[$0.index], $0.score) }
        }
        let hits = picks.map { digest, score in
            hit(
                for: digest, score: score, query: query, among: entries,
                machineID: request.machineID)
        }
        saveIfDue()
        scheduleEviction()
        return AgentSearchReply(
            machineID: request.machineID, hits: hits, indexed: entries.count, pending: pending,
            milliseconds: Int(Date().timeIntervalSince(started) * 1_000))
    }

    static func unique(_ digests: some Sequence<AgentTranscriptDigest>)
        -> [AgentTranscriptDigest]
    {
        var newest: [String: AgentTranscriptDigest] = [:]
        for digest in digests.sorted(by: { $0.path < $1.path }) where digest.isSearchable {
            let key = "\(digest.kind.rawValue)|\(digest.sessionID)"
            if let kept = newest[key], (kept.lastActivity ?? 0) >= (digest.lastActivity ?? 0) {
                continue
            }
            newest[key] = digest
        }
        return newest.values.sorted { $0.path < $1.path }
    }

    public func flush() {
        save()
    }

    func refresh(budget: TimeInterval) -> Int {
        load()
        let found = candidates()
        let present = Set(found.map(\.url.path))
        for path in digests.keys where !present.contains(path) {
            digests[path] = nil
            documents[path] = nil
            version += 1
            dirty = true
        }
        let stale = found.filter { candidate in
            guard let digest = digests[candidate.url.path] else { return true }
            return digest.size != candidate.size || digest.modified != candidate.modified
        }
        .sorted { $0.modified > $1.modified }
        let deadline = Date().addingTimeInterval(budget)
        var pending = 0
        for (position, candidate) in stale.enumerated() {
            if position > 0, Date() > deadline {
                pending = stale.count - position
                break
            }
            if !index(candidate, deadline: deadline) {
                pending = stale.count - position
                break
            }
        }
        loadCodexTitles()
        return pending
    }

    private func index(_ candidate: Candidate, deadline: Date) -> Bool {
        let path = candidate.url.path
        var digest = digests[path] ?? AgentTranscriptDigest(path: path, kind: candidate.kind)
        if candidate.size < digest.offset {
            digest = AgentTranscriptDigest(path: path, kind: candidate.kind)
        }
        let finished: Bool
        do {
            finished = try AgentTranscriptReader.update(
                &digest, url: candidate.url, deadline: deadline)
        } catch {
            return true
        }
        if finished {
            digest.size = candidate.size
            digest.modified = candidate.modified
        }
        if digest.sessionID.isEmpty {
            digest.sessionID = candidate.url.deletingPathExtension().lastPathComponent
        }
        digests[path] = digest
        version += 1
        dirty = true
        return finished
    }

    func candidates() -> [Candidate] {
        var found: [Candidate] = []
        for root in roots.claude { found += files(in: root, kind: .claude, depth: 2) }
        for root in roots.codex { found += files(in: root, kind: .codex, depth: nil) }
        for root in roots.pi { found += files(in: root, kind: .pi, depth: nil) }
        return found
    }

    private func files(in root: URL, kind: AgentTranscriptKind, depth: Int?) -> [Candidate] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
        ]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }
        var found: [Candidate] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                if let depth, enumerator.level >= depth { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, url.pathExtension == "jsonl" else { continue }
            if let depth, enumerator.level != depth { continue }
            found.append(
                Candidate(
                    url: url, kind: kind, size: UInt64(values.fileSize ?? 0),
                    modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
        return found
    }

    private func loadCodexTitles() {
        guard let url = roots.codexTitles,
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
            let modified = values.contentModificationDate?.timeIntervalSince1970,
            modified != codexTitlesModified,
            let data = try? Data(contentsOf: url)
        else { return }
        var titles: [String: String] = [:]
        for line in data.split(separator: 0x0A) {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line))
                    as? [String: Any],
                let id = object["id"] as? String, let name = object["thread_name"] as? String,
                !name.isEmpty
            else { continue }
            titles[id] = AgentTranscriptDigest.clean(name, limit: AgentTranscriptDigest.titleLimit)
        }
        codexTitles = titles
        codexTitlesModified = modified
        version += 1
    }

    private func title(for digest: AgentTranscriptDigest) -> String {
        if digest.kind == .codex, digest.namedTitle == nil,
            let title = codexTitles[digest.sessionID]
        {
            return title
        }
        return digest.title
    }

    private func corpus(for entries: [AgentTranscriptDigest]) -> AgentSearchCorpus {
        if let corpus, corpus.version == version { return corpus.corpus }
        let built = AgentSearchCorpus(entries.map(document(for:)))
        corpus = (version, built)
        return built
    }

    private func document(for digest: AgentTranscriptDigest) -> AgentSearchDocument {
        let title = title(for: digest)
        if let cached = documents[digest.path], cached.offset == digest.offset,
            cached.title == title
        {
            return cached.document
        }
        let document = AgentSearchDocument(digest: digest, title: title)
        documents[digest.path] = CachedDocument(
            offset: digest.offset, title: title, document: document)
        return document
    }

    private func hit(
        for digest: AgentTranscriptDigest, score: Double, query: [String],
        among entries: [AgentTranscriptDigest], machineID: String
    ) -> AgentSearchHit {
        let title = title(for: digest)
        let snippet =
            query.isEmpty
            ? String((digest.prompts.last ?? "").prefix(160))
            : AgentSearchRanker.snippet(
                from: digest.prompts.reversed() + digest.replies.reversed() + [title],
                query: query)
        let placeRank = entries.filter {
            $0.kind == digest.kind && $0.cwd == digest.cwd
                && ($0.lastActivity ?? 0) > (digest.lastActivity ?? 0)
        }.count
        return AgentSearchHit(
            machineID: machineID, kind: digest.kind, sessionID: digest.sessionID,
            path: digest.path, cwd: digest.cwd, branch: digest.branch,
            pullRequest: digest.pullRequest, title: title, snippet: snippet,
            summary: digest.summary, lastActivity: digest.lastActivity, score: score,
            placeRank: placeRank)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let store, let data = try? Data(contentsOf: store),
            let saved = try? JSONDecoder().decode([AgentTranscriptDigest].self, from: data)
        else { return }
        digests = Dictionary(saved.map { ($0.path, $0) }, uniquingKeysWith: { $1 })
        version += 1
    }

    private func saveIfDue() {
        guard dirty, Date().timeIntervalSince(lastSave) >= Self.saveInterval else { return }
        save()
    }

    private func save() {
        guard dirty, let store else { return }
        let entries = digests.values.sorted { $0.path < $1.path }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: store, options: .atomic)) != nil else { return }
        dirty = false
        lastSave = Date()
    }

    private func scheduleEviction() {
        evictionTask?.cancel()
        let delay = idleEviction
        evictionTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.evict()
        }
    }

    private func evict() {
        save()
        digests = [:]
        documents = [:]
        corpus = nil
        codexTitles = [:]
        codexTitlesModified = 0
        loaded = false
        version += 1
    }
}

extension AgentTranscriptDigest {
    var isSearchable: Bool { !prompts.isEmpty || namedTitle != nil }
}
