import EdithKit
import Foundation

public struct UsageModelRow: Decodable, Sendable {
    public let modelName: String?
    public let inputTokens: Double?
    public let outputTokens: Double?
    public let cacheCreationTokens: Double?
    public let cacheReadTokens: Double?
    public let cost: Double?

    public var tokens: Double {
        (inputTokens ?? 0) + (outputTokens ?? 0) + (cacheCreationTokens ?? 0)
            + (cacheReadTokens ?? 0)
    }

    public var name: String { modelName ?? "unknown" }
}

public struct UsageProjectChat: Decodable, Sendable {
    public let id: String?
    public let title: String?
    public let path: String?
    public let source: String?
    public let cost: Double?
    public let tokens: Double?
    public let lastTs: Double?
}

public struct UsageProjectWorktree: Decodable, Sendable {
    public let name: String?
    public let cost: Double?
    public let tokens: Double?
    public let chats: [UsageProjectChat]?
}

public struct UsageProjectMeasure: Decodable, Sendable {
    public let cost: Double?
    public let tokens: Double?
}

public struct UsageProjectSourceBreakdown: Decodable, Sendable {
    public let cost: Double?
    public let tokens: Double?
    public let byModel: [String: UsageProjectMeasure]?
}

public struct UsageProject: Decodable, Sendable {
    public let projectName: String?
    public let repositoryID: String?
    public let repositoryName: String?
    public let repositoryURL: String?
    public let folderName: String?
    public let path: String?
    public let machineName: String?
    public let machineID: String?
    public let cost: Double?
    public let tokens: Double?
    public let bySource: [String: UsageProjectSourceBreakdown]?
    public let chats: [UsageProjectChat]?
    public let worktrees: [UsageProjectWorktree]?

    public var name: String {
        repositoryName ?? projectName ?? folderName ?? path.map {
            URL(fileURLWithPath: $0).lastPathComponent
        }
            ?? "unknown"
    }

    public var stableRepositoryID: String {
        if let repositoryID, !repositoryID.isEmpty { return repositoryID }
        if let repositoryURL, !repositoryURL.isEmpty {
            return "url:\(repositoryURL.lowercased())"
        }
        if let path, !path.isEmpty { return "path:\(path)" }
        return "name:\(name.lowercased())"
    }

    public var resolvedFolderName: String {
        folderName ?? path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? projectName ?? name
    }
}

public struct UsageProjectFolderSummary: Equatable, Sendable {
    public let folderName: String
    public let path: String?
    public let machineName: String?
    public let machineID: String?
    public var cost: Double
    public var tokens: Double

    public var json: JSONValue {
        .object([
            "folderName": .string(folderName),
            "path": .optional(path),
            "machineName": .optional(machineName),
            "machineID": .optional(machineID),
            "cost": .double(cost),
            "tokens": .double(tokens),
        ])
    }
}

public struct UsageProjectSummary: Equatable, Sendable {
    public let repositoryID: String
    public let repositoryName: String
    public let repositoryURL: String?
    public var cost: Double
    public var tokens: Double
    public var folders: [UsageProjectFolderSummary]

    public var json: JSONValue {
        .object([
            "repositoryID": .string(repositoryID),
            "repositoryName": .string(repositoryName),
            "repositoryURL": .optional(repositoryURL),
            "cost": .double(cost),
            "tokens": .double(tokens),
            "folders": .array(folders.map(\.json)),
        ])
    }
}

private struct UsageRepositoryAccumulator {
    var repositoryID: String
    var repositoryName: String
    var repositoryURL: String?
    var cost = 0.0
    var tokens = 0.0
    var folders: [String: UsageProjectFolderSummary] = [:]
}

public struct UsageDay: Decodable, Sendable {
    public let period: String
    public let bySource: [String: [UsageModelRow]]?
    public let projects: [UsageProject]?

    public func rows(sources: Set<String>?) -> [(source: String, row: UsageModelRow)] {
        (bySource ?? [:]).flatMap { source, rows in
            guard sources == nil || sources?.contains(source) == true else {
                return [(String, UsageModelRow)]()
            }
            return rows.map { (source, $0) }
        }
    }
}

public struct UsageSourceMeta: Decodable, Sendable {
    public let label: String?
    public let tool: String?
    public let machine: String?
    public let machineID: String?
}

public enum UsageMachineFilter {
    public static let localNames = ["local", "this-mac", "thismac", "mac"]

    public static func isLocal(_ query: String) -> Bool {
        localNames.contains(query.lowercased().replacingOccurrences(of: " ", with: "-"))
    }

    public static func sources(
        matching query: String, in document: UsageDocument, machineID: UUID? = nil
    ) -> Set<String> {
        let meta = document.sourceMeta ?? [:]
        let ids = document.sources ?? Array(meta.keys)
        guard !isLocal(query) else {
            return Set(ids.filter { meta[$0]?.machine == nil && meta[$0]?.machineID == nil })
        }
        let wanted = machineID?.uuidString.lowercased()
        let needle = query.lowercased()
        return Set(
            ids.filter { id in
                guard let entry = meta[id] else { return false }
                if let wanted, entry.machineID?.lowercased() == wanted { return true }
                return entry.machine?.lowercased() == needle
            })
    }
}

public struct UsageDocument: Decodable, Sendable {
    public let generatedAt: String?
    public let schemaVersion: Int?
    public let sources: [String]?
    public let defaultSources: [String]?
    public let sourceMeta: [String: UsageSourceMeta]?
    public let daily: [UsageDay]

    public static func load(from url: URL = Repo.usageJSON) throws -> UsageDocument {
        guard let data = try? Data(contentsOf: url) else {
            throw CLIFailure.unavailable(
                "no usage data at \(url.path)",
                hint: "run `ed usage refresh` with Edith running, or enable the Agent Usage "
                    + "extension")
        }
        do {
            return try JSONDecoder().decode(UsageDocument.self, from: data)
        } catch {
            throw CLIFailure("could not read \(url.path): \(error.localizedDescription)")
        }
    }
}

public struct UsageTotals: Equatable, Sendable {
    public var cost = 0.0
    public var inputTokens = 0.0
    public var outputTokens = 0.0
    public var cacheCreationTokens = 0.0
    public var cacheReadTokens = 0.0

    public var tokens: Double {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    public mutating func add(_ row: UsageModelRow) {
        cost += row.cost ?? 0
        inputTokens += row.inputTokens ?? 0
        outputTokens += row.outputTokens ?? 0
        cacheCreationTokens += row.cacheCreationTokens ?? 0
        cacheReadTokens += row.cacheReadTokens ?? 0
    }

    public var json: JSONValue {
        .object([
            "cost": .double(cost),
            "tokens": .double(tokens),
            "inputTokens": .double(inputTokens),
            "outputTokens": .double(outputTokens),
            "cacheCreationTokens": .double(cacheCreationTokens),
            "cacheReadTokens": .double(cacheReadTokens),
        ])
    }
}

public enum UsageRange: String, CaseIterable, Sendable {
    case today
    case week
    case month
    case all

    public func includes(period: String, today: Date = Date(), calendar: Calendar = .current)
        -> Bool
    {
        guard let start = start(today: today, calendar: calendar) else { return true }
        return period >= UsageRange.stamp(start, calendar: calendar)
            && period <= UsageRange.stamp(today, calendar: calendar)
    }

    public func start(today: Date, calendar: Calendar) -> Date? {
        let midnight = calendar.startOfDay(for: today)
        switch self {
        case .today: return midnight
        case .week:
            let daysSinceMonday = (calendar.component(.weekday, from: midnight) + 5) % 7
            return calendar.date(byAdding: .day, value: -daysSinceMonday, to: midnight)
        case .month: return calendar.date(byAdding: .day, value: -29, to: midnight)
        case .all: return nil
        }
    }

    public static func stamp(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

public enum UsageAnalysis {
    public static func days(
        _ document: UsageDocument, range: UsageRange, today: Date = Date()
    ) -> [UsageDay] {
        document.daily.filter { range.includes(period: $0.period, today: today) }
    }

    public static func totals(_ days: [UsageDay], sources: Set<String>?) -> UsageTotals {
        var totals = UsageTotals()
        for day in days {
            for entry in day.rows(sources: sources) { totals.add(entry.row) }
        }
        return totals
    }

    public static func bySource(_ days: [UsageDay], sources: Set<String>?) -> [String: UsageTotals]
    {
        var out: [String: UsageTotals] = [:]
        for day in days {
            for entry in day.rows(sources: sources) {
                out[entry.source, default: UsageTotals()].add(entry.row)
            }
        }
        return out
    }

    public static func byModel(_ days: [UsageDay], sources: Set<String>?) -> [String: UsageTotals] {
        var out: [String: UsageTotals] = [:]
        for day in days {
            for entry in day.rows(sources: sources) {
                out[entry.row.name, default: UsageTotals()].add(entry.row)
            }
        }
        return out
    }

    public static func byDay(_ days: [UsageDay], sources: Set<String>?) -> [(String, UsageTotals)] {
        days.map { day in
            var totals = UsageTotals()
            for entry in day.rows(sources: sources) { totals.add(entry.row) }
            return (day.period, totals)
        }
        .sorted { $0.0 < $1.0 }
    }

    public static func byProject(_ days: [UsageDay]) -> [UsageProjectSummary] {
        var repositories: [String: UsageRepositoryAccumulator] = [:]
        for day in days {
            let projects = day.projects ?? []
            addProjectsBySource(projects, day: day, to: &repositories)
        }
        return repositories.values.map { repository in
            UsageProjectSummary(
                repositoryID: repository.repositoryID,
                repositoryName: repository.repositoryName,
                repositoryURL: repository.repositoryURL,
                cost: repository.cost,
                tokens: repository.tokens,
                folders: repository.folders.values.sorted {
                    if $0.cost != $1.cost { return $0.cost > $1.cost }
                    if $0.folderName != $1.folderName { return $0.folderName < $1.folderName }
                    return ($0.path ?? "") < ($1.path ?? "")
                })
        }
        .sorted {
            if $0.cost != $1.cost { return $0.cost > $1.cost }
            return $0.repositoryID < $1.repositoryID
        }
    }

    private static func addProjectsBySource(
        _ projects: [UsageProject], day: UsageDay,
        to repositories: inout [String: UsageRepositoryAccumulator]
    ) {
        for (source, rows) in day.bySource ?? [:] {
            let targetCost = rows.reduce(0) { $0 + ($1.cost ?? 0) }
            let targetTokens = rows.reduce(0) { $0 + $1.tokens }
            let measured = projects.compactMap { project -> (UsageProject, Double, Double)? in
                guard let measure = sourceMeasure(project, source: source) else { return nil }
                return (project, measure.cost, measure.tokens)
            }
            let rawCost = measured.reduce(0) { $0 + $1.1 }
            let rawTokens = measured.reduce(0) { $0 + $1.2 }
            guard rawCost > 0 || rawTokens > 0 else {
                for row in rows {
                    addUnattributed(
                        source: source, model: row.name, cost: row.cost ?? 0,
                        tokens: row.tokens, to: &repositories)
                }
                continue
            }
            for (project, cost, tokens) in measured {
                add(
                    project,
                    cost: normalized(
                        cost, alternate: tokens, rawTotal: rawCost,
                        rawAlternateTotal: rawTokens, target: targetCost),
                    tokens: normalized(
                        tokens, alternate: cost, rawTotal: rawTokens,
                        rawAlternateTotal: rawCost, target: targetTokens),
                    to: &repositories)
            }
        }
    }

    private static func sourceMeasure(_ project: UsageProject, source: String) -> (
        cost: Double, tokens: Double
    )? {
        if let breakdown = project.bySource?[source] {
            let models = Array((breakdown.byModel ?? [:]).values)
            return (
                breakdown.cost ?? models.reduce(0) { $0 + ($1.cost ?? 0) },
                breakdown.tokens ?? models.reduce(0) { $0 + ($1.tokens ?? 0) }
            )
        }
        let chats = (project.chats ?? []) + (project.worktrees ?? []).flatMap { $0.chats ?? [] }
        let matched = chats.filter { $0.source == source }
        guard !matched.isEmpty else { return nil }
        return (
            matched.reduce(0) { $0 + ($1.cost ?? 0) },
            matched.reduce(0) { $0 + ($1.tokens ?? 0) }
        )
    }

    private static func add(
        _ project: UsageProject, cost: Double, tokens: Double,
        to repositories: inout [String: UsageRepositoryAccumulator]
    ) {
        guard cost != 0 || tokens != 0 else { return }
        let repositoryKey = project.stableRepositoryID.lowercased()
        var repository =
            repositories[repositoryKey]
            ?? UsageRepositoryAccumulator(
                repositoryID: project.stableRepositoryID,
                repositoryName: project.name,
                repositoryURL: project.repositoryURL)
        repository.cost += cost
        repository.tokens += tokens
        if repository.repositoryURL == nil { repository.repositoryURL = project.repositoryURL }

        let machineKey = (project.machineID ?? project.machineName ?? "").lowercased()
        let folderKey = [machineKey, project.path ?? project.resolvedFolderName]
            .joined(separator: "\u{1F}")
        var folder =
            repository.folders[folderKey]
            ?? UsageProjectFolderSummary(
                folderName: project.resolvedFolderName,
                path: project.path,
                machineName: project.machineName,
                machineID: project.machineID,
                cost: 0,
                tokens: 0)
        folder.cost += cost
        folder.tokens += tokens
        repository.folders[folderKey] = folder
        repositories[repositoryKey] = repository
    }

    private static func addUnattributed(
        source: String, model: String, cost: Double, tokens: Double,
        to repositories: inout [String: UsageRepositoryAccumulator]
    ) {
        guard cost != 0 || tokens != 0 else { return }
        let repositoryID = "unattributed"
        let repositoryKey = repositoryID
        var repository =
            repositories[repositoryKey]
            ?? UsageRepositoryAccumulator(
                repositoryID: repositoryID, repositoryName: "Unattributed",
                repositoryURL: nil)
        repository.cost += cost
        repository.tokens += tokens
        let folderName = "\(source) / \(model)"
        var folder =
            repository.folders[folderName]
            ?? UsageProjectFolderSummary(
                folderName: folderName, path: nil, machineName: nil, machineID: nil,
                cost: 0, tokens: 0)
        folder.cost += cost
        folder.tokens += tokens
        repository.folders[folderName] = folder
        repositories[repositoryKey] = repository
    }

    private static func normalized(
        _ value: Double, alternate: Double, rawTotal: Double, rawAlternateTotal: Double,
        target: Double
    ) -> Double {
        if rawTotal > 0 { return target * value / rawTotal }
        if rawAlternateTotal > 0 { return target * alternate / rawAlternateTotal }
        return 0
    }
}

public enum LimitsReport {
    public static func providers() -> [(LimitProvider, Date, LimitWindow?, LimitWindow?)] {
        LimitProvider.allCases.compactMap { provider in
            guard let latest = LimitsHistory.latest(provider: provider) else { return nil }
            return (provider, latest.date, latest.session, latest.week)
        }
    }

    public static func window(_ value: LimitWindow?) -> JSONValue {
        guard let value else { return .null }
        return .object([
            "percent": .double(value.percent),
            "resetsAt": .date(value.resetsAt),
            "resetsInSeconds": value.resetsAt.map { JSONValue.double($0.timeIntervalSinceNow) }
                ?? .null,
        ])
    }

    public static func json(
        provider: LimitProvider, observedAt: Date, session: LimitWindow?, week: LimitWindow?
    ) -> JSONValue {
        .object([
            "provider": .string(provider.rawValue),
            "label": .string(provider.label),
            "observedAt": .date(observedAt),
            "session": window(session),
            "weekly": window(week),
        ])
    }
}
