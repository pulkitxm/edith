import Foundation

public struct AgentSessionEnvironment: Sendable {
    public var home: URL
    public var variables: [String: String]
    public var herdr: @Sendable ([String]) async -> String?
    public var isAlive: @Sendable (Int32) -> Bool

    public init(
        home: URL, variables: [String: String] = [:],
        herdr: @escaping @Sendable ([String]) async -> String?,
        isAlive: @escaping @Sendable (Int32) -> Bool
    ) {
        self.home = home
        self.variables = variables
        self.herdr = herdr
        self.isAlive = isAlive
    }

    public static let terminalLines = 4_000
    public static let herdrTimeout: TimeInterval = 10

    public static func live() -> AgentSessionEnvironment {
        AgentSessionEnvironment(
            home: FileManager.default.homeDirectoryForCurrentUser,
            variables: ProcessInfo.processInfo.environment,
            herdr: { arguments in
                guard let executable = HerdrCollector.executable() else { return nil }
                let request = CLICommandRequest(
                    executableURL: executable, arguments: arguments,
                    environment: CLIToolEnvironment.sanitized(), timeout: herdrTimeout,
                    maximumOutputBytes: 8 << 20, discardsStandardError: true)
                guard let result = try? await CLICommandRunner.run(request, onLine: { _ in }),
                    result.terminationStatus == 0
                else { return nil }
                return result.standardOutput
            },
            isAlive: { pid in kill(pid, 0) == 0 || errno == EPERM })
    }
}

public actor AgentSessionSearch {
    public static let shared = AgentSessionSearch(
        environment: .live(),
        store: DataRoot.caches.appendingPathComponent("agent-search/sessions-v3.json"))

    static let saveInterval: TimeInterval = 15

    enum Link: Equatable {
        case file(String, AgentTranscriptKind)
        case opencode(AgentOpenCodeReader.Session)
        case terminal
    }

    struct Meta {
        let id: String
        let cwd: String
        let modified: Double
    }

    let environment: AgentSessionEnvironment
    let store: URL?
    let idleEviction: Duration
    private var digests: [String: AgentTranscriptDigest] = [:]
    private var metas: [String: (modified: Double, meta: Meta)] = [:]
    private var bodies:
        [String: (offset: UInt64, count: Int, prompts: AgentSearchField, replies: AgentSearchField)] =
            [:]
    private var loaded = false
    private var dirty = false
    private var lastSave = Date.distantPast
    private var evictionTask: Task<Void, Never>?

    public init(
        environment: AgentSessionEnvironment, store: URL?,
        idleEviction: Duration = .seconds(600)
    ) {
        self.environment = environment
        self.store = store
        self.idleEviction = idleEviction
    }

    public func search(_ request: AgentSearchRequest, now: Date = Date()) async
        -> AgentSearchReply
    {
        let started = Date()
        load()
        let herdrLinks = await herdrSessions(for: request.targets)
        let deadline = started.addingTimeInterval(request.budget)
        let links = resolve(request.targets, herdrLinks: herdrLinks, deadline: deadline)
        var pending = 0
        var histories: [String: History] = [:]
        for target in request.targets {
            switch links[target.id] ?? .terminal {
            case .file(let path, let kind):
                let (digest, finished) = read(path, kind: kind, deadline: deadline)
                if !finished { pending += 1 }
                histories[target.id] = digest.map(History.transcript) ?? .missing
            case .opencode(let session):
                histories[target.id] = .transcript(
                    AgentOpenCodeReader.digest(for: session, in: openCodeDatabase))
            case .terminal:
                let text = await environment.herdr([
                    "--session", target.session, "pane", "read", target.pane, "--source",
                    "recent", "--lines", String(AgentSessionEnvironment.terminalLines),
                ])
                histories[target.id] = text.map(History.terminal) ?? .missing
            }
        }
        let hits = rank(
            request.targets, histories: histories, query: request.query,
            now: now.timeIntervalSince1970)
        prune(
            keeping: Set(
                links.values.compactMap { link in
                    if case .file(let path, _) = link { return path }
                    return nil
                }))
        saveIfDue()
        scheduleEviction()
        return AgentSearchReply(
            machineID: request.machineID, hits: hits, pending: pending,
            milliseconds: Int(Date().timeIntervalSince(started) * 1_000))
    }

    public func flush() {
        save()
    }

    enum History {
        case transcript(AgentTranscriptDigest)
        case terminal(String)
        case missing
    }

    func rank(
        _ targets: [AgentSearchTarget], histories: [String: History], query: String,
        now: Double
    ) -> [AgentSearchHit] {
        let terms = AgentSearchTerms.terms(query)
        let documents = targets.map { target in
            document(for: target, history: histories[target.id] ?? .missing)
        }
        let order: [(Int, Double)]
        if terms.isEmpty {
            order = targets.indices.map { ($0, 0) }
        } else {
            order = AgentSearchRanker.rank(terms, in: AgentSearchCorpus(documents), now: now)
                .map { ($0.index, $0.score) }
        }
        return order.map { index, score in
            Self.hit(
                for: targets[index], history: histories[targets[index].id] ?? .missing,
                score: score, terms: terms)
        }
    }

    func document(for target: AgentSearchTarget, history: History) -> AgentSearchDocument {
        let folder = target.cwd.split(separator: "/").suffix(3).joined(separator: " ")
        let place = [folder, target.kind].joined(separator: " ")
        switch history {
        case .transcript(let digest):
            let body = body(for: digest)
            return AgentSearchDocument(
                fields: [
                    AgentSearchField(target.title + " " + digest.title),
                    AgentSearchField(
                        [place, digest.branch ?? "", digest.pullRequest ?? ""].joined(
                            separator: " ")),
                    body.prompts, body.replies,
                ], lastActivity: digest.lastActivity)
        case .terminal(let text):
            return AgentSearchDocument(
                fields: [target.title, place, text, ""], lastActivity: nil)
        case .missing:
            return AgentSearchDocument(fields: [target.title, place, "", ""], lastActivity: nil)
        }
    }

    private func body(for digest: AgentTranscriptDigest) -> (
        prompts: AgentSearchField, replies: AgentSearchField
    ) {
        let count = digest.prompts.count + digest.replies.count
        if let cached = bodies[digest.path], cached.offset == digest.offset, cached.count == count {
            return (cached.prompts, cached.replies)
        }
        let prompts = AgentSearchField(digest.prompts.joined(separator: " "))
        let replies = AgentSearchField(digest.replies.joined(separator: " "))
        bodies[digest.path] = (digest.offset, count, prompts, replies)
        return (prompts, replies)
    }

    static func hit(
        for target: AgentSearchTarget, history: History, score: Double, terms: [String]
    ) -> AgentSearchHit {
        switch history {
        case .transcript(let digest):
            let snippet =
                terms.isEmpty
                ? String((digest.prompts.last ?? "").prefix(160))
                : AgentSearchRanker.snippet(
                    from: digest.prompts.reversed() + digest.replies.reversed() + [digest.title],
                    query: terms)
            return AgentSearchHit(
                id: target.id, source: .transcript, sessionID: digest.sessionID,
                title: digest.title, snippet: snippet, summary: digest.summary,
                lastActivity: digest.lastActivity, score: score)
        case .terminal(let text):
            let lines = text.split(whereSeparator: \.isNewline).map {
                AgentTranscriptDigest.clean(String($0))
            }
            .filter { !$0.isEmpty }
            let snippet =
                terms.isEmpty
                ? String((lines.last ?? "").prefix(160))
                : AgentSearchRanker.snippet(from: lines.reversed(), query: terms)
            return AgentSearchHit(
                id: target.id, source: .terminal, title: target.title, snippet: snippet,
                summary: String(lines.suffix(3).joined(separator: " ").prefix(320)),
                lastActivity: nil, score: score)
        case .missing:
            return AgentSearchHit(
                id: target.id, source: .none, title: target.title, snippet: "", summary: "",
                lastActivity: nil, score: score)
        }
    }

    func herdrSessions(for targets: [AgentSearchTarget]) async -> [String: String] {
        var links: [String: String] = [:]
        for session in Set(targets.map(\.session)).sorted() {
            guard let output = await environment.herdr(["--session", session, "api", "snapshot"])
            else { continue }
            for (pane, value) in Self.agentSessions(in: output) {
                links["\(session)|\(pane)"] = value
            }
        }
        return links
    }

    static func agentSessions(in snapshot: String) -> [String: String] {
        guard
            let object = HerdrListParser.firstJSON(in: snapshot) as? [String: Any],
            let result = object["result"] as? [String: Any],
            let body = result["snapshot"] as? [String: Any],
            let agents = body["agents"] as? [[String: Any]]
        else { return [:] }
        var sessions: [String: String] = [:]
        for agent in agents {
            guard let pane = agent["pane_id"] as? String,
                let session = agent["agent_session"] as? [String: Any],
                let value = session["value"] as? String, !value.isEmpty
            else { continue }
            sessions[pane] = value
        }
        return sessions
    }

    func resolve(
        _ targets: [AgentSearchTarget], herdrLinks: [String: String],
        deadline: Date = .distantFuture
    ) -> [String: Link] {
        var links: [String: Link] = [:]
        var claimed = Set<String>()
        var unlinked: [AgentSearchTarget] = []
        let openCode =
            targets.contains { AgentTranscriptKind(herdrKind: $0.kind) == .opencode }
            ? AgentOpenCodeReader.sessions(in: openCodeDatabase) : []
        for target in targets {
            guard let kind = AgentTranscriptKind(herdrKind: target.kind) else {
                links[target.id] = .terminal
                continue
            }
            guard let value = herdrLinks["\(target.session)|\(target.pane)"] else {
                unlinked.append(target)
                continue
            }
            if let link = link(kind: kind, id: value, openCode: openCode) {
                links[target.id] = link
                claimed.insert(value)
            } else {
                unlinked.append(target)
            }
        }
        let live = liveClaudeSessions()
        for target in unlinked {
            guard let kind = AgentTranscriptKind(herdrKind: target.kind) else { continue }
            let place = Self.standardized(target.cwd)
            let candidates: [Meta]
            switch kind {
            case .claude:
                candidates = live.filter { Self.standardized($0.cwd) == place }
            case .codex, .pi:
                candidates = self.metas(kind).filter { Self.standardized($0.cwd) == place }
            case .opencode:
                candidates = openCode.filter { Self.standardized($0.directory) == place }.map {
                    Meta(id: $0.id, cwd: $0.directory, modified: $0.updated)
                }
            }
            let open = candidates.filter { !claimed.contains($0.id) }
                .sorted { $0.modified > $1.modified }
            let chosen =
                open.first {
                    title(
                        of: $0.id, kind: kind, openCode: openCode, matches: target.title,
                        deadline: deadline)
                } ?? open.first
            guard let chosen, let link = link(kind: kind, id: chosen.id, openCode: openCode)
            else {
                links[target.id] = .terminal
                continue
            }
            claimed.insert(chosen.id)
            links[target.id] = link
        }
        return links
    }

    private func link(
        kind: AgentTranscriptKind, id: String, openCode: [AgentOpenCodeReader.Session]
    ) -> Link? {
        if id.hasPrefix("/"), FileManager.default.fileExists(atPath: id) {
            return .file(id, kind)
        }
        switch kind {
        case .claude:
            return claudeFile(id).map { .file($0, .claude) }
        case .codex, .pi:
            return metaPaths(kind).first { $0.meta.id == id || $0.path.contains(id) }
                .map { .file($0.path, kind) }
        case .opencode:
            return openCode.first { $0.id == id }.map(Link.opencode)
        }
    }

    private func title(
        of id: String, kind: AgentTranscriptKind, openCode: [AgentOpenCodeReader.Session],
        matches paneTitle: String, deadline: Date
    ) -> Bool {
        let wanted = Self.normalizedTitle(paneTitle)
        guard !wanted.isEmpty else { return false }
        let known: String?
        switch kind {
        case .claude:
            known = claudeFile(id).flatMap { read($0, kind: .claude, deadline: deadline).0 }?.title
        case .codex:
            known = codexTitles()[id]
        case .pi:
            known =
                metaPaths(.pi).first { $0.meta.id == id }
                .flatMap { read($0.path, kind: .pi, deadline: deadline).0 }?.title
        case .opencode:
            known = openCode.first { $0.id == id }?.title
        }
        guard let known else { return false }
        let have = Self.normalizedTitle(known)
        return !have.isEmpty && (have.hasPrefix(wanted) || wanted.hasPrefix(have))
    }

    private var openCodeDatabase: URL {
        AgentOpenCodeReader.database(home: environment.home, environment: environment.variables)
    }

    static func normalizedTitle(_ title: String) -> String {
        let trimmed = title.drop { !($0.isLetter || $0.isNumber) }
        return AgentTranscriptDigest.clean(String(trimmed)).lowercased()
    }

    static func standardized(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    private func claudeFile(_ id: String) -> String? {
        let projects = environment.home.appendingPathComponent(".claude/projects")
        guard
            let folders = try? FileManager.default.contentsOfDirectory(
                at: projects, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return nil }
        for folder in folders {
            let file = folder.appendingPathComponent(id + ".jsonl")
            if FileManager.default.fileExists(atPath: file.path) { return file.path }
        }
        return nil
    }

    private func liveClaudeSessions() -> [Meta] {
        let folder = environment.home.appendingPathComponent(".claude/sessions")
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        return files.compactMap { file in
            guard file.pathExtension == "json", let data = try? Data(contentsOf: file),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let pid = object["pid"] as? Int, let id = object["sessionId"] as? String,
                environment.isAlive(Int32(pid))
            else { return nil }
            let started = (object["startedAt"] as? Double) ?? 0
            return Meta(id: id, cwd: object["cwd"] as? String ?? "", modified: started / 1_000)
        }
    }

    private func roots(_ kind: AgentTranscriptKind) -> [URL] {
        switch kind {
        case .codex:
            [
                environment.home.appendingPathComponent(".codex/sessions"),
                environment.home.appendingPathComponent(".codex/archived_sessions"),
            ]
        case .pi: [environment.home.appendingPathComponent(".pi/agent/sessions")]
        case .claude, .opencode: []
        }
    }

    private func metas(_ kind: AgentTranscriptKind) -> [Meta] {
        metaPaths(kind).map(\.meta)
    }

    private func metaPaths(_ kind: AgentTranscriptKind) -> [(path: String, meta: Meta)] {
        var found: [(path: String, meta: Meta)] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        for root in roots(kind) {
            guard
                let enumerator = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                    values.isRegularFile == true
                else { continue }
                let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                if let cached = metas[url.path], cached.modified == modified {
                    found.append((url.path, cached.meta))
                    continue
                }
                var digest = AgentTranscriptDigest(path: url.path, kind: kind)
                AgentTranscriptReader.head(&digest, url: url)
                let meta = Meta(id: digest.sessionID, cwd: digest.cwd, modified: modified)
                metas[url.path] = (modified, meta)
                found.append((url.path, meta))
            }
        }
        return found.sorted { $0.meta.modified > $1.meta.modified }
    }

    private func codexTitles() -> [String: String] {
        let url = environment.home.appendingPathComponent(".codex/session_index.jsonl")
        guard let data = try? Data(contentsOf: url) else { return [:] }
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
        return titles
    }

    private func read(_ path: String, kind: AgentTranscriptKind, deadline: Date)
        -> (AgentTranscriptDigest?, Bool)
    {
        let url = URL(fileURLWithPath: path)
        guard
            let values = try? url.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey,
            ])
        else { return (digests[path], true) }
        let size = UInt64(values.fileSize ?? 0)
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        var digest = digests[path] ?? AgentTranscriptDigest(path: path, kind: kind)
        if digest.size == size, digest.modified == modified { return (digest, true) }
        if size < digest.offset { digest = AgentTranscriptDigest(path: path, kind: kind) }
        guard
            let finished = try? AgentTranscriptReader.update(&digest, url: url, deadline: deadline)
        else { return (digests[path], true) }
        if finished {
            digest.size = size
            digest.modified = modified
        }
        if digest.sessionID.isEmpty {
            digest.sessionID = url.deletingPathExtension().lastPathComponent
        }
        if kind == .codex, digest.namedTitle == nil, let title = codexTitles()[digest.sessionID] {
            digest.namedTitle = title
        }
        digests[path] = digest
        dirty = true
        return (digest, finished)
    }

    private func prune(keeping paths: Set<String>) {
        let stale = digests.keys.filter { !paths.contains($0) }
        guard !stale.isEmpty else { return }
        for path in stale {
            digests[path] = nil
            bodies[path] = nil
        }
        dirty = true
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let store, let data = try? Data(contentsOf: store),
            let saved = try? JSONDecoder().decode([AgentTranscriptDigest].self, from: data)
        else { return }
        digests = Dictionary(saved.map { ($0.path, $0) }, uniquingKeysWith: { $1 })
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
        metas = [:]
        bodies = [:]
        loaded = false
    }
}
