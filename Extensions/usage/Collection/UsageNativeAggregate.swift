import Foundation

struct UsageNativeAggregate {
    struct Money {
        var tokens = 0.0
        var cost = 0.0
        mutating func add(_ tokens: Double, _ cost: Double) {
            self.tokens += tokens
            self.cost += cost
        }
    }

    struct SourceSlice {
        var money = Money()
        var models: [String: Money] = [:]
    }

    struct Slice {
        var money = Money()
        var sources: [String: SourceSlice] = [:]

        mutating func add(_ event: UsageNativeEvent, cost: Double) {
            let total = event.tokens.total
            money.add(total, cost)
            sources[event.source, default: .init()].money.add(total, cost)
            sources[event.source]!.models[event.model, default: .init()].add(total, cost)
        }

        var node: [String: Any] {
            [
                "tokens": money.tokens, "cost": money.cost,
                "bySource": sources.mapValues { source in
                    [
                        "tokens": source.money.tokens, "cost": source.money.cost,
                        "byModel": source.models.mapValues {
                            ["tokens": $0.tokens, "cost": $0.cost] as [String: Any]
                        },
                    ] as [String: Any]
                },
            ]
        }
    }

    struct Order: Comparable {
        let timestamp: Double
        let source: String
        let identity: String
        static func < (left: Self, right: Self) -> Bool {
            (left.timestamp, left.source, left.identity) < (
                right.timestamp, right.source, right.identity
            )
        }
    }

    struct Chat {
        var id: String
        var source: String
        var path: String
        var tokens = 0.0
        var cost = 0.0
        var first: Order
        var last: Order
        var title: (Order, String)?

        mutating func add(_ event: UsageNativeEvent, cost: Double, order: Order) {
            tokens += event.tokens.total
            self.cost += cost
            if order < first { first = order; path = event.cwd }
            if last < order { last = order }
            if let text = event.title, title.map({ $0.0 < order }) ?? true { title = (order, text) }
        }

        var node: [String: Any] {
            let name =
                title?.1 ?? (id.isEmpty ? "Untitled chat" : "Chat " + id.prefix(8))
            return [
                "id": id, "path": path, "title": name, "source": source, "tokens": tokens,
                "cost": cost, "firstTs": first.timestamp * 1000, "lastTs": last.timestamp * 1000,
            ]
        }
    }

    struct Worktree {
        var tokens = 0.0
        var cost = 0.0
        var chats: [String: Chat] = [:]
    }

    struct Project {
        let meta: UsageNativeProject
        var slice = Slice()
        var chats: [String: Chat] = [:]
        var worktrees: [String: Worktree] = [:]
    }

    struct Model {
        var input = 0.0
        var output = 0.0
        var creation = 0.0
        var read = 0.0
        var cost = 0.0
        var missing = false
        var unpriced = 0.0
        var fallback = false
    }

    struct Day {
        var sources: [String: [String: Model]] = [:]
        var hours: [Slice] = Array(repeating: Slice(), count: 24)
        var paths: [[String: Slice]] = Array(repeating: [:], count: 24)
        var projects: [String: Project] = [:]
    }

    struct Session {
        var id: String
        var source: String
        var cost = 0.0
        var tokens = 0.0
        var last: Date
    }

    private(set) var days: [String: Day] = [:]
    private(set) var sources: Set<String> = []
    private(set) var unpricedModels: Set<String> = []
    private var tokens = UsageNativeTokens()
    private var cost = 0.0
    private var bySource: [String: Money] = [:]
    private var sessions: [String: Session] = [:]

    mutating func add(
        _ event: UsageNativeEvent, cost: Double, missing: Bool, fallback: Bool,
        project: UsageNativeProject, period: String, hour: Int
    ) {
        let total = event.tokens.total
        sources.insert(event.source)
        if missing { unpricedModels.insert(event.model) }
        tokens.input += event.tokens.input
        tokens.output += event.tokens.output
        tokens.creation += event.tokens.creation
        tokens.read += event.tokens.read
        self.cost += cost
        bySource[event.source, default: .init()].add(total, cost)
        var day = days[period] ?? Day()
        days[period] = nil
        var model = day.sources[event.source]?[event.model] ?? Model()
        model.input += event.tokens.input
        model.output += event.tokens.output
        model.creation += event.tokens.creation
        model.read += event.tokens.read
        model.cost += cost
        if missing { model.missing = true; model.unpriced += total }
        if fallback { model.fallback = true }
        day.sources[event.source, default: [:]][event.model] = model
        if event.detailAvailable {
            day.hours[hour].add(event, cost: cost)
            day.paths[hour][event.cwd, default: .init()].add(event, cost: cost)
            let order = Order(
                timestamp: event.timestamp.timeIntervalSince1970, source: event.source,
                identity: event.identity ?? "")
            let chatKey = event.source + "\u{0}" + event.session
            if !project.root.isEmpty {
                let key = project.repositoryID + "\u{0}" + project.root
                var entry = day.projects[key] ?? Project(meta: project)
                day.projects[key] = nil
                entry.slice.add(event, cost: cost)
                if let worktree = project.worktree {
                    var node = entry.worktrees[worktree] ?? Worktree()
                    node.tokens += total
                    node.cost += cost
                    node.chats[chatKey, default: Self.chat(event, order)].add(
                        event, cost: cost, order: order)
                    entry.worktrees[worktree] = node
                } else {
                    entry.chats[chatKey, default: Self.chat(event, order)].add(
                        event, cost: cost, order: order)
                }
                day.projects[key] = entry
            }
            if !event.session.isEmpty {
                var session =
                    sessions[chatKey]
                    ?? Session(
                        id: event.session, source: event.source, last: event.timestamp)
                session.cost += cost
                session.tokens += total
                if event.timestamp > session.last { session.last = event.timestamp }
                sessions[chatKey] = session
            }
        }
        days[period] = day
    }

    private static func chat(_ event: UsageNativeEvent, _ order: Order) -> Chat {
        .init(
            id: event.session, source: event.source, path: event.cwd, first: order, last: order)
    }

    func totals() -> [String: Any] {
        [
            "tokens": tokens.total, "cost": cost, "inputTokens": tokens.input,
            "outputTokens": tokens.output, "cacheCreationTokens": tokens.creation,
            "cacheReadTokens": tokens.read,
            "bySource": bySource.mapValues { ["tokens": $0.tokens, "cost": $0.cost] },
        ]
    }

    func sessionNodes() -> [[String: Any]] {
        sessions.values.map { value -> [String: Any] in
            [
                "id": value.id, "source": value.source, "cost": value.cost, "tokens": value.tokens,
                "lastActivity": ISO8601DateFormatter().string(from: value.last),
            ]
        }.sorted {
            ($0["source"] as! String, $0["id"] as! String) < (
                $1["source"] as! String, $1["id"] as! String
            )
        }
    }

    func dailyBlocks() -> [[String: Any]] {
        days.keys.sorted().map { period in
            let day = days[period]!
            var block: [String: Any] = ["period": period, "bySource": Self.dailySources(day)]
            block["hours"] = (0..<24).map { hour -> [String: Any] in
                var node = day.hours[hour].node
                node["byPath"] = day.paths[hour].mapValues { $0.node }
                return node
            }
            block["projects"] = Self.projectNodes(day)
            return block
        }
    }

    private static func dailySources(_ day: Day) -> [String: [[String: Any]]] {
        day.sources.mapValues { models in
            models.keys.sorted().map { name in
                let model = models[name]!
                var tokens = UsageNativeTokens()
                tokens.input = model.input; tokens.output = model.output
                tokens.creation = model.creation; tokens.read = model.read
                return [
                    "tokens": tokens.total, "cost": model.cost, "inputTokens": model.input,
                    "outputTokens": model.output, "cacheCreationTokens": model.creation,
                    "cacheReadTokens": model.read, "modelName": name,
                    "costMissing": model.missing, "unpricedTokens": model.unpriced,
                    "isFallback": model.fallback,
                ]
            }
        }
    }

    private static func chatNodes(_ chats: [String: Chat]) -> [[String: Any]] {
        chats.values.map(\.node).sorted {
            ($0["tokens"] as! Double, $0["id"] as! String) > (
                $1["tokens"] as! Double, $1["id"] as! String
            )
        }
    }

    private static func projectNodes(_ day: Day) -> [[String: Any]] {
        day.projects.values.map { entry -> [String: Any] in
            let project = entry.meta
            var node = entry.slice.node
            node["projectName"] = project.repositoryName
            node["repositoryID"] = project.repositoryID
            node["repositoryName"] = project.repositoryName
            node["repositoryURL"] = project.repositoryURL ?? ""
            node["folderName"] = project.folderName
            node["path"] = project.root
            node["attribution"] = ["method": "working-directory"]
            node["chats"] = chatNodes(entry.chats)
            node["worktrees"] = entry.worktrees.map { name, worktree -> [String: Any] in
                [
                    "name": name, "tokens": worktree.tokens, "cost": worktree.cost,
                    "chats": chatNodes(worktree.chats),
                ]
            }.sorted { ($0["tokens"] as! Double) > ($1["tokens"] as! Double) }
            return node
        }.sorted {
            ($0["tokens"] as! Double, $0["repositoryName"] as! String) > (
                $1["tokens"] as! Double, $1["repositoryName"] as! String
            )
        }
    }
}
