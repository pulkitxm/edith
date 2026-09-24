import Foundation

public struct UsageAttributionRepository: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var url: String?
}

public struct UsageAttributionDecision: Codable, Sendable, Equatable {
    public enum Method: String, Codable, Sendable {
        case name
        case jev
    }

    public var method: Method
    public var repository: UsageAttributionRepository?
    public var confidence: Double?
    public var folder: String
    public var machine: String?
    public var title: String?
    public var decidedAt: Date
}

public struct UsageAttributionCache: Codable, Sendable, Equatable {
    public static let fileName = "usage-attribution.json"
    public static let maximumBytes = 16 * 1_024 * 1_024

    public var version = 1
    public var decisions: [String: UsageAttributionDecision] = [:]

    public static func url(dataDir: URL = Repo.dataDir) -> URL {
        dataDir.appendingPathComponent(fileName)
    }

    public static func load(dataDir: URL = Repo.dataDir) -> UsageAttributionCache {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard
            let data = try? UsageDataFiles.readRegularFile(
                at: url(dataDir: dataDir), maximumBytes: maximumBytes),
            let cache = try? decoder.decode(UsageAttributionCache.self, from: data)
        else { return UsageAttributionCache() }
        return cache
    }

    public func save(dataDir: URL = Repo.dataDir) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        try UsageDataFiles.write(try encoder.encode(self), to: Self.url(dataDir: dataDir))
    }

    public static func reset(dataDir: URL = Repo.dataDir) throws {
        guard FileManager.default.fileExists(atPath: url(dataDir: dataDir).path) else { return }
        try FileManager.default.removeItem(at: url(dataDir: dataDir))
    }
}

public struct UsageAttributionMatcher: Sendable {
    static let suffixes = [
        "-worktrees", "-worktree", "-main", "-master", "-fix", "-dev", "-copy", "-backup", "-old",
        "-wip",
    ]
    static let generic: Set<String> = [
        "users", "home", "root", "library", "documents", "desktop", "downloads", "developer",
        "src", "code", "projects", "repos", "repositories", "work", "workspace", "dev", "tmp",
        "private", "var", "scripts", "app", "api", "web", "docs", "site", "test", "tests", "demo",
        "main", "server", "client", "unknown", "packages", "sources",
    ]

    private let byName: [String: Set<String>]
    private let bySlug: [String: String]
    private let repositories: [String: UsageAttributionRepository]

    public init(repositories: [UsageAttributionRepository]) {
        var byName: [String: Set<String>] = [:]
        var bySlug: [String: String] = [:]
        var index: [String: UsageAttributionRepository] = [:]
        for repository in repositories {
            index[repository.id] = repository
            let slug = repository.id.lowercased().replacingOccurrences(of: "github.com/", with: "")
            bySlug[slug] = repository.id
            for name in [repository.name, String(slug.split(separator: "/").last ?? "")] {
                byName[Self.normalized(name), default: []].insert(repository.id)
            }
        }
        self.byName = byName
        self.bySlug = bySlug
        self.repositories = index
    }

    static func normalized(_ value: String) -> String {
        var name = value.lowercased()
        if name.hasSuffix(".git") { name.removeLast(4) }
        while let suffix = suffixes.first(where: { name.hasSuffix($0) && name.count > $0.count }) {
            name.removeLast(suffix.count)
        }
        return name
    }

    public func folder(name: String, path: String) -> UsageAttributionRepository? {
        var components = path.split(separator: "/").map(String.init)
        if ["Users", "home"].contains(components.first) {
            components.removeFirst(min(2, components.count))
        }
        return unique(([name] + components).map(Self.normalized), minimumLength: 3)
    }

    public func title(_ title: String) -> UsageAttributionRepository? {
        guard !UsageAttribution.isGeneric(title: title) else { return nil }
        var ids = Set<String>()
        let words = title.lowercased().split {
            !($0.isLetter || $0.isNumber || "-_./".contains($0))
        }
        for word in words {
            let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "./"))
            let slug = trimmed.replacingOccurrences(of: "github.com/", with: "")
            if let id = bySlug[slug] {
                ids.insert(id)
            } else {
                ids.formUnion(candidates(Self.normalized(trimmed), minimumLength: 4))
            }
        }
        return ids.count == 1 ? ids.first.flatMap { repositories[$0] } : nil
    }

    private func candidates(_ token: String, minimumLength: Int) -> Set<String> {
        guard token.count >= minimumLength, !Self.generic.contains(token) else { return [] }
        return byName[token] ?? []
    }

    private func unique(_ tokens: [String], minimumLength: Int) -> UsageAttributionRepository? {
        let ids = tokens.reduce(into: Set<String>()) {
            $0.formUnion(candidates($1, minimumLength: minimumLength))
        }
        return ids.count == 1 ? ids.first.flatMap { repositories[$0] } : nil
    }
}

public enum UsageAttribution {
    static let identityKeys = ["projectName", "repositoryID", "repositoryName", "repositoryURL"]

    struct Target: Equatable {
        let repository: UsageAttributionRepository
        let method: UsageAttributionDecision.Method
    }

    struct Resolver {
        let decisions: [String: UsageAttributionDecision]
        let matcher: UsageAttributionMatcher

        func folder(_ project: [String: Any]) -> Target? {
            if let decision = decisions[folderKey(project)] {
                return decision.repository.map { Target(repository: $0, method: decision.method) }
            }
            return matcher.folder(name: string(project["folderName"]), path: localPath(project))
                .map { Target(repository: $0, method: .name) }
        }

        func chat(_ chat: [String: Any], in project: [String: Any]) -> Target? {
            guard let key = chatKey(chat, in: project) else { return nil }
            if let decision = decisions[key] {
                return decision.repository.map { Target(repository: $0, method: decision.method) }
            }
            return matcher.title(string(chat["title"])).map {
                Target(repository: $0, method: .name)
            }
        }
    }

    public static func attributed(_ data: Data, cache: UsageAttributionCache) -> Data {
        let result = apply(data, cache: cache)
        guard result != data, result.count <= UsageDataFiles.maximumUsageDocumentBytes,
            UsageHistory.isValidDocument(result)
        else { return data }
        return result
    }

    static func apply(_ data: Data, cache: UsageAttributionCache) -> Data {
        guard var document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return data }
        let retention = (document["historyRetention"] as? [String: Any])?["blocks"]
        let retained = Set(
            (retention as? [[String: Any]] ?? []).compactMap { $0["period"] as? String })
        let resolver = Resolver(
            decisions: cache.decisions,
            matcher: UsageAttributionMatcher(repositories: knownRepositories(document)))
        var days = document["daily"] as? [[String: Any]] ?? []
        var changed = false
        for index in days.indices {
            guard let period = days[index]["period"] as? String, !retained.contains(period),
                let projects = days[index]["projects"] as? [[String: Any]],
                let next = attribute(projects, resolver: resolver)
            else { continue }
            days[index]["projects"] = next
            changed = true
        }
        guard changed else { return data }
        document["daily"] = days
        return (try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]))
            ?? data
    }

    public static func knownRepositories(_ document: [String: Any]) -> [UsageAttributionRepository]
    {
        var seen: [String: UsageAttributionRepository] = [:]
        for day in document["daily"] as? [[String: Any]] ?? [] {
            for project in day["projects"] as? [[String: Any]] ?? []
            where isGitHub(project) && project["attribution"] == nil {
                let id = string(project["repositoryID"])
                guard seen[id] == nil else { continue }
                let name = string(project["repositoryName"])
                seen[id] = UsageAttributionRepository(
                    id: id, name: name.isEmpty ? String(id.split(separator: "/").last ?? "") : name,
                    url: project["repositoryURL"] as? String)
            }
        }
        return seen.keys.sorted().compactMap { seen[$0] }
    }

    public static func isGeneric(title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "Untitled chat"
            || trimmed.range(of: #"^Chat [0-9A-Za-z_-]{1,8}$"#, options: .regularExpression) != nil
    }

    static func attribute(_ projects: [[String: Any]], resolver: Resolver) -> [[String: Any]]? {
        var list: [[String: Any]] = []
        var changed = false
        for project in projects {
            if project["attribution"] != nil, !stillHolds(project, resolver: resolver) {
                list.append(restored(project))
                changed = true
            } else {
                list.append(project)
            }
        }
        if changed { list = coalesced(list) }
        var index = 0
        while index < list.count {
            let project = list[index]
            index += 1
            guard project["attribution"] == nil, !isGitHub(project) else { continue }
            if !isUnknown(project) {
                guard let target = resolver.folder(project) else { continue }
                let next = moved(project, to: target, scope: "folder")
                guard let existing = list.firstIndex(where: { key($0) == key(next) }) else {
                    list[index - 1] = next
                    changed = true
                    continue
                }
                guard
                    (list[existing]["attribution"] as? [String: Any])?["scope"] as? String
                        == "folder"
                else { continue }
                list[existing] = combined(list[existing], next)
                list.remove(at: index - 1)
                index -= 1
                changed = true
                continue
            }
            var groups: [String: (target: Target, ids: Set<String>)] = [:]
            for chat in project["chats"] as? [[String: Any]] ?? [] {
                guard let target = resolver.chat(chat, in: project) else { continue }
                let id = target.repository.id
                let method: UsageAttributionDecision.Method =
                    groups[id]?.target.method == .jev ? .jev : target.method
                groups[id] = (
                    Target(repository: target.repository, method: method),
                    (groups[id]?.ids ?? []).union([string(chat["id"])])
                )
            }
            for id in groups.keys.sorted() {
                guard let group = groups[id],
                    split(&list, at: index - 1, target: group.target, chats: group.ids)
                else { continue }
                changed = true
            }
        }
        guard changed else { return nil }
        return list.filter {
            !isUnknown($0) || !($0["bySource"] as? [String: Any] ?? [:]).isEmpty
        }
    }

    private static func stillHolds(_ project: [String: Any], resolver: Resolver) -> Bool {
        let attribution = project["attribution"] as? [String: Any] ?? [:]
        let original = restored(project)
        let id = string(project["repositoryID"])
        let method = string(attribution["method"])
        if string(attribution["scope"]) == "folder" {
            let target = resolver.folder(original)
            return target?.repository.id == id && target?.method.rawValue == method
        }
        let targets = (project["chats"] as? [[String: Any]] ?? []).map {
            resolver.chat($0, in: original)
        }
        guard !targets.isEmpty, targets.allSatisfy({ $0?.repository.id == id }) else {
            return false
        }
        return (targets.contains { $0?.method == .jev } ? "jev" : "name") == method
    }

    private static func split(
        _ list: inout [[String: Any]], at index: Int, target: Target, chats ids: Set<String>
    ) -> Bool {
        var remaining = list[index]
        let chats = remaining["chats"] as? [[String: Any]] ?? []
        let moving = chats.filter { ids.contains(string($0["id"])) }
        let every =
            chats
            + (remaining["worktrees"] as? [[String: Any]] ?? []).flatMap {
                $0["chats"] as? [[String: Any]] ?? []
            }
        var kept = remaining["bySource"] as? [String: Any] ?? [:]
        var taken: [String: Any] = [:]
        for (source, value) in kept {
            guard let breakdown = value as? [String: Any] else { continue }
            let share = fraction(
                of: moving.filter { chatSource($0, in: remaining) == source },
                in: every.filter { chatSource($0, in: remaining) == source })
            guard share > 0 else { continue }
            if share >= 1 {
                taken[source] = breakdown
                kept[source] = nil
            } else {
                let parts = divided(breakdown, share)
                taken[source] = parts.moved
                kept[source] = parts.kept
            }
        }
        guard !taken.isEmpty else { return false }
        var part = moved(remaining, to: target, scope: "chat")
        part["chats"] = moving
        part["worktrees"] = [[String: Any]]()
        setSources(&part, taken)
        remaining["chats"] = chats.filter { !ids.contains(string($0["id"])) }
        setSources(&remaining, kept)
        if let existing = list.firstIndex(where: { key($0) == key(part) }) {
            guard (list[existing]["attribution"] as? [String: Any])?["scope"] as? String == "chat"
            else { return false }
            var merged = combined(list[existing], part)
            if target.method == .jev {
                merged["attribution"] = part["attribution"]
            }
            list[existing] = merged
        } else {
            list.insert(part, at: index + 1)
        }
        list[index] = remaining
        return true
    }

    private static func fraction(of moving: [[String: Any]], in all: [[String: Any]]) -> Double {
        let cost = all.reduce(0) { $0 + number($1["cost"]) }
        if cost > 0 { return min(1, moving.reduce(0) { $0 + number($1["cost"]) } / cost) }
        let tokens = all.reduce(0) { $0 + number($1["tokens"]) }
        guard tokens > 0 else { return 0 }
        return min(1, moving.reduce(0) { $0 + number($1["tokens"]) } / tokens)
    }

    private static func divided(_ breakdown: [String: Any], _ share: Double) -> (
        moved: [String: Any], kept: [String: Any]
    ) {
        var moved: [String: Any] = [:]
        var kept: [String: Any] = [:]
        for (model, value) in breakdown["byModel"] as? [String: Any] ?? [:] {
            let usage = value as? [String: Any] ?? [:]
            let cost = number(usage["cost"])
            let tokens = number(usage["tokens"])
            let movedCost = cost * share
            let movedTokens = (tokens * share).rounded(.down)
            moved[model] = ["cost": movedCost, "tokens": movedTokens]
            kept[model] = ["cost": cost - movedCost, "tokens": tokens - movedTokens]
        }
        return (summed(moved), summed(kept))
    }

    private static func summed(_ models: [String: Any]) -> [String: Any] {
        let values = models.values.compactMap { $0 as? [String: Any] }
        return [
            "byModel": models, "cost": values.reduce(0) { $0 + number($1["cost"]) },
            "tokens": values.reduce(0) { $0 + number($1["tokens"]) },
        ]
    }

    private static func setSources(_ project: inout [String: Any], _ sources: [String: Any]) {
        let values = sources.values.compactMap { $0 as? [String: Any] }
        project["bySource"] = sources
        project["cost"] = values.reduce(0) { $0 + number($1["cost"]) }
        project["tokens"] = values.reduce(0) { $0 + number($1["tokens"]) }
    }

    private static func combined(_ base: [String: Any], _ other: [String: Any]) -> [String: Any] {
        var out = base
        var sources = base["bySource"] as? [String: Any] ?? [:]
        for (source, value) in other["bySource"] as? [String: Any] ?? [:] {
            var models = (sources[source] as? [String: Any])?["byModel"] as? [String: Any] ?? [:]
            for (model, usage) in (value as? [String: Any])?["byModel"] as? [String: Any] ?? [:] {
                let left = models[model] as? [String: Any] ?? [:]
                let right = usage as? [String: Any] ?? [:]
                models[model] = [
                    "cost": number(left["cost"]) + number(right["cost"]),
                    "tokens": number(left["tokens"]) + number(right["tokens"]),
                ]
            }
            sources[source] = summed(models)
        }
        setSources(&out, sources)
        out["chats"] =
            (base["chats"] as? [[String: Any]] ?? []) + (other["chats"] as? [[String: Any]] ?? [])
        out["worktrees"] =
            (base["worktrees"] as? [[String: Any]] ?? [])
            + (other["worktrees"] as? [[String: Any]] ?? [])
        return out
    }

    private static func coalesced(_ projects: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for project in projects {
            if let index = out.firstIndex(where: { key($0) == key(project) }) {
                out[index] = combined(out[index], project)
            } else {
                out.append(project)
            }
        }
        return out
    }

    private static func moved(
        _ project: [String: Any], to target: Target, scope: String
    ) -> [String: Any] {
        var out = project
        var from: [String: Any] = [:]
        for field in identityKeys { from[field] = project[field] ?? NSNull() }
        out["attribution"] = ["method": target.method.rawValue, "scope": scope, "from": from]
        out["projectName"] = target.repository.name
        out["repositoryID"] = target.repository.id
        out["repositoryName"] = target.repository.name
        out["repositoryURL"] = target.repository.url ?? NSNull()
        return out
    }

    private static func restored(_ project: [String: Any]) -> [String: Any] {
        var out = project
        let from = (project["attribution"] as? [String: Any])?["from"] as? [String: Any] ?? [:]
        for field in identityKeys { out[field] = from[field] ?? NSNull() }
        out["attribution"] = nil
        return out
    }

    private static func key(_ project: [String: Any]) -> String {
        [string(project["repositoryID"]), string(project["machineID"]), string(project["path"])]
            .joined(separator: "\u{1F}")
    }

    static func isGitHub(_ project: [String: Any]) -> Bool {
        string(project["repositoryID"]).hasPrefix("github.com/")
    }

    static func isUnknown(_ project: [String: Any]) -> Bool {
        string(project["repositoryName"]) == "unknown" && string(project["folderName"]) == "unknown"
    }

    static func folderKey(_ project: [String: Any]) -> String {
        "folder|\(string(project["machineID"]))|\(string(project["repositoryID"]))"
    }

    static func chatKey(_ chat: [String: Any], in project: [String: Any]) -> String? {
        let id = string(chat["id"])
        guard !id.isEmpty, let source = chatSource(chat, in: project) else { return nil }
        return "chat|\(source)|\(string(project["machineID"]))|\(id)"
    }

    static func chatSource(_ chat: [String: Any], in project: [String: Any]) -> String? {
        let source = string(chat["source"])
        if !source.isEmpty { return source }
        let sources = (project["bySource"] as? [String: Any] ?? [:]).keys
        return sources.count == 1 ? sources.first : nil
    }

    static func localPath(_ project: [String: Any]) -> String {
        let path = string(project["path"])
        guard path.hasPrefix("machine:"),
            let range = path.range(of: #"^machine:[^:]+:"#, options: .regularExpression)
        else { return path }
        return String(path[range.upperBound...])
    }

    static func string(_ value: Any?) -> String { value as? String ?? "" }

    static func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
}
