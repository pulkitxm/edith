import Foundation

public enum UsageAttributionAdvisor {
    public static let perRunLimit = 40
    public static let threshold = 0.8
    public static let titleLimit = 80
    public static let titleCount = 5
    public static let purpose = "usage.attribution"
    public static let question = "repository"
    public static let noneOption = "none"

    struct Unit {
        let key: String
        let folder: String
        let path: String
        let machine: String
        let isChat: Bool
        var sources: Set<String> = []
        var titles: [String] = []
        var cost = 0.0
    }

    private static let queue = UsageAttributionQueue()

    public static func schedule(
        dataDir: URL = Repo.dataDir, decider: @escaping @Sendable () async -> JevDeciding?
    ) async {
        await queue.submit { await run(dataDir: dataDir, decider: await decider()) }
    }

    public static func run(dataDir: URL = Repo.dataDir, decider: JevDeciding?) async {
        guard
            let data = try? UsageDataFiles.readRegularFile(
                at: dataDir.appendingPathComponent("usage.json"))
        else { return }
        let cache = UsageAttributionCache.load(dataDir: dataDir)
        let next = await advise(data, cache: cache, decider: decider)
        guard next != cache else { return }
        try? next.save(dataDir: dataDir)
    }

    public static func advise(
        _ data: Data, cache: UsageAttributionCache, decider: JevDeciding?,
        limit: Int = perRunLimit, now: Date = Date()
    ) async -> UsageAttributionCache {
        guard let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return cache }
        let repositories = UsageAttribution.knownRepositories(document)
        guard !repositories.isEmpty else { return cache }
        let matcher = UsageAttributionMatcher(repositories: repositories)
        var next = cache
        var questions: [Unit] = []
        for unit in units(document) where next.decisions[unit.key] == nil {
            let match =
                unit.isChat
                ? matcher.title(unit.titles.first ?? "")
                : matcher.folder(name: unit.folder, path: unit.path)
            if let match {
                next.decisions[unit.key] = decision(unit, .name, match, confidence: nil, now)
            } else if !unit.isChat || !unit.titles.isEmpty {
                questions.append(unit)
            }
        }
        guard let decider else { return next }
        for unit in questions.prefix(max(0, limit)) {
            guard
                let answer = try? await decider.decide(
                    request(unit, repositories: repositories), purpose: purpose
                ).answer(question)
            else { break }
            let probability = answer.chosenProbability ?? 0
            let chosen =
                probability >= threshold ? repositories.first { $0.id == answer.choice } : nil
            next.decisions[unit.key] = decision(unit, .jev, chosen, confidence: probability, now)
        }
        return next
    }

    static func request(_ unit: Unit, repositories: [UsageAttributionRepository]) -> JevRequest {
        let options =
            repositories.prefix(JevQuestion.maximumOptions - 1).map {
                JevOption($0.id, "\($0.name) (\($0.id))")
            } + [JevOption(noneOption, "none of these; keep it as its own folder")]
        return JevRequest(
            state: .fields([
                "folder": unit.folder, "path": String(unit.path.suffix(160)),
                "machine": unit.machine,
                "source": unit.sources.sorted().joined(separator: ", "),
                "titles": unit.titles.prefix(titleCount).map {
                    JevText.compact($0, limit: titleLimit)
                }.joined(separator: "\n"),
            ]),
            questions: [
                question: .choice(
                    "Which repository was the work in `folder` at `path` done for, judging by the chat `titles`?",
                    options: options)
            ])
    }

    static func units(_ document: [String: Any]) -> [Unit] {
        var units: [String: Unit] = [:]
        for day in document["daily"] as? [[String: Any]] ?? [] {
            for project in day["projects"] as? [[String: Any]] ?? []
            where !UsageAttribution.isGitHub(project) && project["attribution"] == nil {
                let machine = project["machineName"] as? String ?? "this Mac"
                let chats = project["chats"] as? [[String: Any]] ?? []
                guard UsageAttribution.isUnknown(project) else {
                    let key = UsageAttribution.folderKey(project)
                    var unit =
                        units[key]
                        ?? Unit(
                            key: key, folder: UsageAttribution.string(project["folderName"]),
                            path: UsageAttribution.localPath(project), machine: machine,
                            isChat: false)
                    unit.sources.formUnion(sources(project))
                    unit.cost += UsageAttribution.number(project["cost"])
                    for title in chats.map({ UsageAttribution.string($0["title"]) })
                    where !UsageAttribution.isGeneric(title: title) && !unit.titles.contains(title)
                        && unit.titles.count < titleCount
                    {
                        unit.titles.append(title)
                    }
                    units[key] = unit
                    continue
                }
                for chat in chats {
                    guard let key = UsageAttribution.chatKey(chat, in: project) else { continue }
                    let title = UsageAttribution.string(chat["title"])
                    var unit =
                        units[key]
                        ?? Unit(
                            key: key, folder: "unknown", path: "", machine: machine, isChat: true,
                            titles: UsageAttribution.isGeneric(title: title) ? [] : [title])
                    unit.sources.formUnion(
                        UsageAttribution.chatSource(chat, in: project).map { [local($0)] } ?? [])
                    unit.cost += UsageAttribution.number(chat["cost"])
                    units[key] = unit
                }
            }
        }
        return units.values.sorted { $0.cost == $1.cost ? $0.key < $1.key : $0.cost > $1.cost }
    }

    private static func sources(_ project: [String: Any]) -> [String] {
        (project["bySource"] as? [String: Any] ?? [:]).keys.map(local)
    }

    private static func local(_ source: String) -> String {
        guard let range = source.range(of: #"^machine:[^:]+:"#, options: .regularExpression)
        else { return source }
        return String(source[range.upperBound...])
    }

    private static func decision(
        _ unit: Unit, _ method: UsageAttributionDecision.Method,
        _ repository: UsageAttributionRepository?, confidence: Double?, _ now: Date
    ) -> UsageAttributionDecision {
        UsageAttributionDecision(
            method: method, repository: repository, confidence: confidence, folder: unit.folder,
            machine: unit.machine, title: unit.isChat ? unit.titles.first : nil, decidedAt: now)
    }
}

actor UsageAttributionQueue {
    private var running: Task<Void, Never>?
    private var pending: (@Sendable () async -> Void)?

    func submit(_ work: @escaping @Sendable () async -> Void) {
        guard running == nil else {
            pending = work
            return
        }
        start(work)
    }

    func settled() async {
        while let running { await running.value }
    }

    private func start(_ work: @escaping @Sendable () async -> Void) {
        running = Task(priority: .utility) {
            await work()
            await self.finish()
        }
    }

    private func finish() {
        running = nil
        guard let next = pending else { return }
        pending = nil
        start(next)
    }
}
