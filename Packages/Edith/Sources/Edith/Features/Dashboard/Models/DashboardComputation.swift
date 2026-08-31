import EdithKit
import Foundation

struct DashboardIngestDigest {
    var sortedPeriods: [String] = []
    var allSources: [SourceInfo] = []
    var sourceIndex: [String: Int] = [:]
    var machineGroups: [MachineGroup] = []
    var machineCollectionDates: [String: Date] = [:]
    var defaultSources: [String] = []
    var allModels: [String] = []
    var modelIndex: [String: Int] = [:]
    var defaultModels: [String] = []
    var allProjectPaths: [ProjectPath] = []
    var monthOptions: [String] = []
    var heatDetail: [String: HeatDay] = [:]
    var calendarDays: [DayPoint] = []
}

struct DashboardSnapshot {
    var series: [DayDatum] = []
    var kpis: [KPI] = []
    var modelTotals: [ModelTotal] = []
    var dow: [DOWDatum] = []
    var hourlyAll: [HourDatum] = []
    var hourlyUnattributedTokens = 0.0
    var hourlyUnattributedCost = 0.0
    var pathUnattributedTokens = 0.0
    var pathUnattributedCost = 0.0
    var modelUnfilterableCost = 0.0
    var projects: [ProjectAgg] = []
    var projectTree: [ProjTreeRow] = []
    var meta = MetaLine()
    var chartData = DashChartData()
}

struct DashboardComputeRequest {
    let data: DashUsage
    let sortedPeriods: [String]
    let allSources: [SourceInfo]
    let allModels: [String]
    let calendarDays: [DayPoint]
    let range: DashRange
    let selectedSources: Set<String>
    let selectedModels: Set<String>
    let selectedPaths: Set<String>
    let sortColumn: TableColumn
    let sortAscending: Bool
    let projSortKey: ProjSortKey
    let projSortAscending: Bool
    let calendar: Calendar
}

enum DashboardComputation {
    static let unattributedCostModel = "unattributed-cost"
    static let stackedSeriesLimit = 8
    static let weeklyBucketThresholdDays = 120

    static let ymd: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func snapshot(_ request: DashboardComputeRequest) -> DashboardSnapshot? {
        DashboardFilterComputer(request).run()
    }

    static func isUnattributedCost(_ row: DashUsage.Model) -> Bool {
        let name = row.modelName ?? "unknown"
        return name == unattributedCostModel
            || (row.tokens == 0 && (row.cost ?? 0) > 0)
    }

    static func modelLabel(_ model: String) -> String {
        model == unattributedCostModel ? "Unattributed cost" : DashFmt.shortModel(model)
    }

    static func path(_ path: String, isWithin scope: String) -> Bool {
        let caseSensitive = !path.hasPrefix("/") || !scope.hasPrefix("/")
        let value = normalizedPath(path, caseSensitive: caseSensitive)
        let parent = normalizedPath(scope, caseSensitive: caseSensitive)
        guard !value.isEmpty, !parent.isEmpty else { return false }
        return value == parent || value.hasPrefix(parent + "/")
    }

    static func normalizedPath(_ path: String, caseSensitive: Bool) -> String {
        let raw = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = caseSensitive ? raw : raw.lowercased()
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    static func pathInScope(_ path: String?, selectedPaths: Set<String>) -> Bool {
        guard !selectedPaths.isEmpty else { return true }
        guard let path, !path.isEmpty else { return false }
        return selectedPaths.contains { self.path(path, isWithin: $0) }
    }

    static func registryNames() -> [String: String] {
        var names: [String: String] = [:]
        for machine in MachineRegistry.machines() {
            names[machine.id.uuidString.lowercased()] = machine.name
        }
        return names
    }

    static func agentName(_ entry: DashUsage.Meta?, id: String, local: Bool) -> String {
        guard let entry else { return id }
        if local { return entry.label ?? entry.tool ?? id }
        return entry.tool ?? entry.label ?? id
    }

    static func groupByMachine(
        _ ids: [String], meta: [String: DashUsage.Meta], naming: [String: String]
    ) -> [MachineGroup] {
        var order: [String] = []
        var sources: [String: [String]] = [:]
        var names: [String: String] = [:]
        var agents: [String: [String]] = [:]
        for id in ids {
            let entry = meta[id]
            let key = entry?.machineID?.lowercased() ?? entry?.machine ?? MachineGroup.localID
            let local = key == MachineGroup.localID
            if sources[key] == nil {
                order.append(key)
                names[key] =
                    key == MachineGroup.localID
                    ? "This Mac" : (naming[key] ?? entry?.machine ?? key)
            }
            sources[key, default: []].append(id)
            agents[key, default: []].append(agentName(entry, id: id, local: local))
        }
        let groups = order.map {
            MachineGroup(
                id: $0, name: names[$0] ?? $0, sourceIDs: sources[$0] ?? [],
                agentNames: agents[$0] ?? [])
        }
        guard groups.count > 1 else { return [] }
        return groups
    }

    static func modelTotalLess(
        _ a: ModelTotal, _ b: ModelTotal, column: TableColumn, ascending: Bool
    ) -> Bool {
        func cmp<T: Comparable>(_ x: T, _ y: T) -> Bool { ascending ? x < y : x > y }
        switch column {
        case .model: return ascending ? a.model < b.model : a.model > b.model
        case .cost: return cmp(a.cost, b.cost)
        case .share: return cmp(a.share, b.share)
        case .tokens: return cmp(a.tokens, b.tokens)
        case .input: return cmp(a.input, b.input)
        case .output: return cmp(a.output, b.output)
        case .cacheRead: return cmp(a.cacheRead, b.cacheRead)
        case .days: return cmp(a.days, b.days)
        }
    }

    static func projSortableLess(
        _ a: some ProjSortable, _ b: some ProjSortable, key: ProjSortKey, ascending: Bool
    ) -> Bool {
        func cmp<T: Comparable>(_ x: T, _ y: T) -> Bool { ascending ? x < y : x > y }
        switch key {
        case .name: return cmp(a.sortName, b.sortName)
        case .tokens: return cmp(a.tokens, b.tokens)
        case .cost: return cmp(a.cost, b.cost)
        case .share: return cmp(a.share, b.share)
        case .days: return cmp(a.days, b.days)
        case .dur: return cmp(a.dur, b.dur)
        case .lastActive: return cmp(a.lastActive, b.lastActive)
        }
    }

    static func sortTree(
        _ rows: [ProjTreeRow], key: ProjSortKey, ascending: Bool
    ) -> [ProjTreeRow] {
        func less(_ a: some ProjSortable, _ b: some ProjSortable) -> Bool {
            projSortableLess(a, b, key: key, ascending: ascending)
        }
        return rows.map { row in
            var r = row
            r.folders = row.folders.map { folder in
                var f = folder
                f.chats = folder.chats.sorted(by: less)
                f.worktrees = folder.worktrees.map { worktree in
                    var w = worktree
                    w.chats = worktree.chats.sorted(by: less)
                    return w
                }
                .sorted(by: less)
                return f
            }
            .sorted(by: less)
            return r
        }
        .sorted(by: less)
    }

    static func digest(_ parsed: DashUsage, calendar: Calendar) -> DashboardIngestDigest {
        var digest = DashboardIngestDigest()
        digest.sortedPeriods = parsed.daily.map(\.period).sorted()
        let srcIds = (parsed.sources ?? []).filter { id in
            parsed.daily.contains { ($0.bySource?[id]?.isEmpty == false) }
        }
        let ids = srcIds.isEmpty ? (parsed.sources ?? ["cli"]) : srcIds
        digest.allSources = ids.map {
            SourceInfo(id: $0, label: parsed.sourceMeta?[$0]?.label ?? $0)
        }
        digest.sourceIndex = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        digest.machineGroups = groupByMachine(
            ids, meta: parsed.sourceMeta ?? [:], naming: registryNames())
        digest.machineCollectionDates = Dictionary(
            parsed.machines?.compactMap { machine -> (String, Date)? in
                guard let rawID = machine.id, let id = UUID(uuidString: rawID),
                    let collectedAt = EdithDate.parseISO(machine.collectedAt)
                else { return nil }
                return (id.uuidString.lowercased(), collectedAt)
            } ?? [],
            uniquingKeysWith: max)
        var defaults = (parsed.defaultSources ?? ids).filter { ids.contains($0) }
        if defaults.isEmpty { defaults = ids }
        digest.defaultSources = defaults

        var usageByModel: [String: (cost: Double, tokens: Double)] = [:]
        for day in parsed.daily {
            for (_, rows) in day.bySource ?? [:] {
                for row in rows where !isUnattributedCost(row) {
                    let name = row.modelName ?? "unknown"
                    var usage = usageByModel[name] ?? (0, 0)
                    usage.cost += row.cost ?? 0
                    usage.tokens += row.tokens
                    usageByModel[name] = usage
                }
            }
        }
        digest.allModels = usageByModel.sorted {
            if $0.value.cost != $1.value.cost { return $0.value.cost > $1.value.cost }
            if $0.value.tokens != $1.value.tokens { return $0.value.tokens > $1.value.tokens }
            return $0.key < $1.key
        }.map(\.key)
        digest.modelIndex = Dictionary(
            uniqueKeysWithValues: digest.allModels.enumerated().map { ($1, $0) })
        digest.defaultModels = digest.allModels

        var byPath: [String: (name: String, tokens: Double)] = [:]
        for day in parsed.daily {
            for p in day.projects ?? [] {
                guard let path = p.path, !path.isEmpty else { continue }
                let last = URL(fileURLWithPath: path).lastPathComponent
                let name = p.folderName ?? (last.isEmpty ? p.projectName ?? "unknown" : last)
                byPath[path, default: (name, 0)].tokens += p.tokens ?? 0
            }
        }
        digest.allProjectPaths =
            byPath
            .map { ProjectPath(path: $0.key, name: $0.value.name, tokens: $0.value.tokens) }
            .sorted { ($0.tokens, $1.path) > ($1.tokens, $0.path) }

        var months = Set<String>()
        for d in parsed.daily where d.period.count >= 7 {
            months.insert(String(d.period.prefix(7)))
        }
        digest.monthOptions = months.sorted(by: >)

        let heat = activity(parsed, sources: digest.allSources, calendar: calendar)
        digest.heatDetail = heat.detail
        digest.calendarDays = heat.days
        return digest
    }
}

extension DashboardComputation {
    fileprivate static func activity(
        _ parsed: DashUsage, sources: [SourceInfo], calendar: Calendar
    ) -> (detail: [String: HeatDay], days: [DayPoint]) {
        let labels = Dictionary(
            sources.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        var detail: [String: HeatDay] = [:]
        var dates: [Date] = []
        for day in parsed.daily {
            guard let date = ymd.date(from: day.period) else { continue }
            dates.append(date)
            detail[day.period] = heatDay(day, date: date, sourceLabels: labels)
        }
        guard let first = dates.min(), let last = dates.max() else { return ([:], []) }
        let days = calendarPoints(detail: detail, from: first, to: last, calendar: calendar)
        return (detail, days)
    }

    fileprivate static func heatDay(
        _ day: DashUsage.Day, date: Date, sourceLabels: [String: String]
    ) -> HeatDay {
        var heat = HeatDay(date: date)
        var modelTokens: [String: Double] = [:]
        var sourceTokens: [String: Double] = [:]
        for (source, rows) in day.bySource ?? [:] {
            for row in rows {
                heat.input += row.inputTokens ?? 0
                heat.output += row.outputTokens ?? 0
                heat.cacheCreate += row.cacheCreationTokens ?? 0
                heat.cacheRead += row.cacheReadTokens ?? 0
                heat.cost += row.cost ?? 0
                guard row.tokens > 0 else { continue }
                let name = row.modelName ?? "unknown"
                modelTokens[name, default: 0] += row.tokens
                sourceTokens[source, default: 0] += row.tokens
            }
        }
        heat.tokens = heat.input + heat.output + heat.cacheCreate + heat.cacheRead
        heat.models = modelTokens.sorted { $0.value > $1.value }.map {
            NamedValue(id: $0.key, name: modelLabel($0.key), value: $0.value)
        }
        heat.sources = sourceTokens.sorted { $0.value > $1.value }.map {
            NamedValue(id: $0.key, name: sourceLabels[$0.key] ?? $0.key, value: $0.value)
        }
        heatProjects(day, heat: &heat)
        heatPeak(day, heat: &heat)
        return heat
    }

    fileprivate static func heatProjects(_ day: DashUsage.Day, heat: inout HeatDay) {
        let projects = day.projects ?? []
        let raw = projects.map { project -> UsageAmount in
            let sources = Array((project.bySource ?? [:]).values)
            let sourceTokens = sources.reduce(0) {
                $0 + (sourceAmount($1, model: "", useSourceTotal: true)?.tokens ?? 0)
            }
            let sourceCost = sources.reduce(0) {
                $0 + (sourceAmount($1, model: "", useSourceTotal: true)?.cost ?? 0)
            }
            return UsageAmount(
                tokens: project.tokens ?? sourceTokens,
                cost: project.cost ?? sourceCost)
        }
        let rawTokens = raw.reduce(0) { $0 + $1.tokens }
        let rawCost = raw.reduce(0) { $0 + $1.cost }
        let attributableTokens = min(heat.tokens, rawTokens)
        var repositoryTokens: [String: (name: String, tokens: Double)] = [:]
        var attributedTokens = 0.0
        for (index, project) in projects.enumerated() {
            let amount = raw[index]
            let tokens = normalizedPart(
                amount.tokens, alternate: amount.cost, rawTotal: rawTokens,
                rawAlternateTotal: rawCost, target: attributableTokens)
            guard tokens > 0 else { continue }
            attributedTokens += tokens
            let repository = repositoryIdentity(project)
            let current = repositoryTokens[repository.id]?.tokens ?? 0
            repositoryTokens[repository.id] = (repository.name, current + tokens)
            heat.chatCount += (project.chats ?? []).count
            heat.chatCount += (project.worktrees ?? []).reduce(0) {
                $0 + ($1.chats ?? []).count
            }
        }
        let unattributedTokens = max(0, heat.tokens - attributedTokens)
        if unattributedTokens > 0 {
            repositoryTokens["unattributed"] = ("Unattributed", unattributedTokens)
        }
        heat.projects = repositoryTokens.sorted { $0.value.tokens > $1.value.tokens }.map {
            NamedValue(id: $0.key, name: $0.value.name, value: $0.value.tokens)
        }
        heat.projCount = heat.projects.count
    }

    fileprivate static func heatPeak(_ day: DashUsage.Day, heat: inout HeatDay) {
        let hours = Array((day.hours ?? []).prefix(24))
        let tokens = hours.map { hour in
            hour.tokens
                ?? (hour.bySource ?? [:]).values.reduce(0) {
                    $0 + (sourceAmount($1, model: "", useSourceTotal: true)?.tokens ?? 0)
                }
        }
        let costs = hours.map { hour in
            hour.cost
                ?? (hour.bySource ?? [:]).values.reduce(0) {
                    $0 + (sourceAmount($1, model: "", useSourceTotal: true)?.cost ?? 0)
                }
        }
        let totalTokens = tokens.reduce(0, +)
        let totalCost = costs.reduce(0, +)
        guard totalTokens > 0 || totalCost > 0 else { return }
        var peakValue = 0.0
        for index in hours.indices {
            let value = totalTokens > 0 ? tokens[index] : costs[index]
            if value > peakValue {
                peakValue = value
                heat.peakTokens = tokens[index]
                heat.peakHour = index
            }
        }
    }

    fileprivate static func calendarPoints(
        detail: [String: HeatDay], from: Date, to: Date, calendar: Calendar
    ) -> [DayPoint] {
        let first = calendar.startOfDay(for: min(from, to))
        let last = calendar.startOfDay(for: max(from, to))
        let firstWeekday = (calendar.component(.weekday, from: first) + 5) % 7
        let lastWeekday = (calendar.component(.weekday, from: last) + 5) % 7
        var day = calendar.date(byAdding: .day, value: -firstWeekday, to: first) ?? first
        let end = calendar.date(byAdding: .day, value: 6 - lastWeekday, to: last) ?? last
        var points: [DayPoint] = []
        while day <= end {
            let key = ymd.string(from: day)
            points.append(DayPoint(id: key, date: day, cost: detail[key]?.cost ?? 0))
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? end.addingTimeInterval(1)
        }
        return points
    }

    fileprivate static func sourceAmount(
        _ breakdown: DashUsage.SourceBreakdown, model: String, useSourceTotal: Bool
    ) -> UsageAmount? {
        if useSourceTotal {
            let models = Array((breakdown.byModel ?? [:]).values)
            return UsageAmount(
                tokens: breakdown.tokens ?? models.reduce(0) { $0 + ($1.tokens ?? 0) },
                cost: breakdown.cost ?? models.reduce(0) { $0 + ($1.cost ?? 0) })
        }
        guard let usage = breakdown.byModel?[model] else { return nil }
        return UsageAmount(tokens: usage.tokens ?? 0, cost: usage.cost ?? 0)
    }

    fileprivate static func repositoryIdentity(
        _ project: DashUsage.Project
    ) -> RepositoryIdentity {
        let repositoryURL = nonempty(project.repositoryURL) ?? ""
        let explicitID = nonempty(project.repositoryID)
        let normalizedURL = normalizeRepositoryURL(repositoryURL)
        let path = nonempty(project.path) ?? ""
        let machine = nonempty(project.machineID) ?? nonempty(project.machineName) ?? ""
        let fallbackName = nonempty(project.projectName) ?? "unknown"
        let id =
            explicitID.map {
                $0.lowercased().hasPrefix("github.com/") ? $0.lowercased() : $0
            }
            ?? (normalizedURL.isEmpty
                ? "folder:\(machine.lowercased()):\(path.lowercased()):\(fallbackName.lowercased())"
                : "url:\(normalizedURL)")
        let urlName =
            normalizedURL.split(separator: "/").last.map(String.init)?
            .replacingOccurrences(of: ".git", with: "")
        let name = nonempty(project.repositoryName) ?? nonempty(urlName) ?? fallbackName
        return RepositoryIdentity(id: id, name: name, url: repositoryURL)
    }

    fileprivate static func folderIdentity(
        _ project: DashUsage.Project, repository: RepositoryIdentity
    ) -> FolderIdentity {
        let path = nonempty(project.path) ?? ""
        let machineName = nonempty(project.machineName) ?? ""
        let machineID = nonempty(project.machineID) ?? ""
        let last = path.isEmpty ? "" : URL(fileURLWithPath: path).lastPathComponent
        let name =
            nonempty(project.folderName) ?? nonempty(last) ?? nonempty(project.projectName)
            ?? repository.name
        let machineKey = machineID.isEmpty ? machineName.lowercased() : machineID.lowercased()
        let location =
            path.isEmpty || machineID.isEmpty ? (path.isEmpty ? name : path).lowercased() : path
        return FolderIdentity(
            id: "\(repository.id)|folder:\(machineKey):\(location)", name: name, path: path,
            machineName: machineName, machineID: machineID)
    }

    fileprivate static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    fileprivate static func normalizeRepositoryURL(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalized.hasSuffix("/") { normalized.removeLast() }
        if normalized.hasSuffix(".git") { normalized.removeLast(4) }
        return normalized
    }
}

private struct UsageAmount {
    var tokens = 0.0
    var cost = 0.0
}

private struct ProjectAttributionKey: Hashable {
    let source: String
    let model: String
}

private struct ProjectAllocation {
    let project: DashUsage.Project
    var amount = UsageAmount()
}

private struct HourlyAllocation {
    var tokens = [Double](repeating: 0, count: 24)
    var cost = [Double](repeating: 0, count: 24)
    var unattributed = UsageAmount()
}

private struct RepositoryIdentity {
    let id: String
    let name: String
    let url: String
}

private struct FolderIdentity {
    let id: String
    let name: String
    let path: String
    let machineName: String
    let machineID: String
}

private struct ChatAcc {
    var title = ""
    var tokens = 0.0
    var cost = 0.0
    var source = ""
    var lastActive = ""
    var firstTs = 0.0
    var lastTs = 0.0
    var days = Set<String>()

    mutating func merge(_ c: DashUsage.Chat, period: String, scale: DayScale) {
        tokens += scale.tokens(c.tokens ?? 0, c.cost ?? 0)
        cost += scale.cost(c.cost ?? 0, c.tokens ?? 0)
        if let s = c.source, !s.isEmpty { source = s }
        if let t = c.title, !t.isEmpty { title = t }
        if period > lastActive { lastActive = period }
        if let f = c.firstTs, f > 0, firstTs == 0 || f < firstTs { firstTs = f }
        if let l = c.lastTs, l > lastTs { lastTs = l }
        if (c.tokens ?? 0) > 0 || (c.cost ?? 0) > 0 { days.insert(period) }
    }

    var dur: Double { firstTs > 0 && lastTs > firstTs ? lastTs - firstTs : 0 }
}

private struct RepoAccum {
    let name: String
    let url: String
    var folders: [String: ProjAccum] = [:]
}

private struct ProjAccum {
    let name: String
    let path: String
    let machineName: String
    let machineID: String
    var main: [String: ChatAcc] = [:]
    var wts: [String: [String: ChatAcc]] = [:]
    var fallbackTokens = 0.0
    var fallbackCost = 0.0
    var fallbackDays = Set<String>()

    mutating func absorb(
        _ p: DashUsage.Project, period: String, scale: DayScale,
        include: (DashUsage.Chat) -> Bool
    ) {
        if !ProjAccum.hasTokenedChat(p), (p.tokens ?? 0) > 0 || (p.cost ?? 0) > 0 {
            fallbackTokens += scale.tokens(p.tokens ?? 0, p.cost ?? 0)
            fallbackCost += scale.cost(p.cost ?? 0, p.tokens ?? 0)
            fallbackDays.insert(period)
        }
        for c in p.chats ?? [] where include(c) {
            main[c.id ?? "", default: ChatAcc()].merge(c, period: period, scale: scale)
        }
        for wt in p.worktrees ?? [] {
            for c in wt.chats ?? [] where include(c) {
                wts[wt.name ?? "", default: [:]][c.id ?? "", default: ChatAcc()]
                    .merge(c, period: period, scale: scale)
            }
        }
    }

    static func hasTokenedChat(_ p: DashUsage.Project) -> Bool {
        let tokened = { (c: DashUsage.Chat) in (c.tokens ?? 0) > 0 || (c.cost ?? 0) > 0 }
        return (p.chats ?? []).contains(where: tokened)
            || (p.worktrees ?? []).contains { ($0.chats ?? []).contains(where: tokened) }
    }

    mutating func addFallback(_ amount: UsageAmount, period: String) {
        fallbackTokens += amount.tokens
        fallbackCost += amount.cost
        fallbackDays.insert(period)
    }
}

private final class DashPathMatcher {
    private struct Scope {
        let sensitive: String
        let insensitive: String
        let absolute: Bool
    }

    private let scopes: [Scope]
    private var verdicts: [String: Bool] = [:]

    init(_ selected: Set<String>) {
        scopes = selected.map {
            Scope(
                sensitive: DashboardComputation.normalizedPath($0, caseSensitive: true),
                insensitive: DashboardComputation.normalizedPath($0, caseSensitive: false),
                absolute: $0.hasPrefix("/"))
        }
    }

    func inScope(_ path: String?) -> Bool {
        guard !scopes.isEmpty else { return true }
        guard let path, !path.isEmpty else { return false }
        if let cached = verdicts[path] { return cached }
        let sensitive = DashboardComputation.normalizedPath(path, caseSensitive: true)
        let insensitive = sensitive.lowercased()
        let absolute = path.hasPrefix("/")
        let hit = scopes.contains { scope in
            let caseSensitive = !absolute || !scope.absolute
            let value = caseSensitive ? sensitive : insensitive
            let parent = caseSensitive ? scope.sensitive : scope.insensitive
            guard !value.isEmpty, !parent.isEmpty else { return false }
            return value == parent || value.hasPrefix(parent + "/")
        }
        verdicts[path] = hit
        return hit
    }
}

private struct DashboardFilterComputer {
    let data: DashUsage
    let sortedPeriods: [String]
    let allSources: [SourceInfo]
    let allModels: [String]
    let calendarDays: [DayPoint]
    let range: DashRange
    let selectedSources: Set<String>
    let selectedModels: Set<String>
    let selectedPaths: Set<String>
    let sortColumn: TableColumn
    let sortAscending: Bool
    let projSortKey: ProjSortKey
    let projSortAscending: Bool
    let cal: Calendar
    let fullModelScope: Bool
    let matcher: DashPathMatcher

    init(_ request: DashboardComputeRequest) {
        data = request.data
        sortedPeriods = request.sortedPeriods
        allSources = request.allSources
        allModels = request.allModels
        calendarDays = request.calendarDays
        range = request.range
        selectedSources = request.selectedSources
        selectedModels = request.selectedModels
        selectedPaths = request.selectedPaths
        sortColumn = request.sortColumn
        sortAscending = request.sortAscending
        projSortKey = request.projSortKey
        projSortAscending = request.projSortAscending
        cal = request.calendar
        fullModelScope = request.selectedModels == Set(request.allModels)
        matcher = DashPathMatcher(request.selectedPaths)
    }

    private func parseYMD(_ s: String) -> Date? { DashboardComputation.ymd.date(from: s) }
    private func ymdStr(_ d: Date) -> String { DashboardComputation.ymd.string(from: d) }

    private func pathInScope(_ path: String?) -> Bool { matcher.inScope(path) }

    private func chatVisible(_ source: String?) -> Bool {
        guard let source, !source.isEmpty else { return true }
        return selectedSources.contains(source)
    }

    private func chatInScope(_ c: DashUsage.Chat, fallback: String?) -> Bool {
        chatVisible(c.source) && pathInScope(c.path ?? fallback)
    }

    private func knownPath(_ p: DashUsage.Project) -> String? {
        p.path
    }

    private func sourceLabel(_ id: String) -> String {
        allSources.first { $0.id == id }?.label ?? id
    }

    private func window() -> (from: Date, to: Date)? {
        guard let first = sortedPeriods.first, let last = sortedPeriods.last,
            let earliest = parseYMD(first), let dataLatest = parseYMD(last)
        else { return nil }
        let today = cal.startOfDay(for: Date())
        let latest = max(today, dataLatest)
        switch range {
        case .all: return (earliest, latest)
        case .today: return (today, today)
        case .yesterday:
            let y = cal.date(byAdding: .day, value: -1, to: today) ?? today
            return (y, y)
        case .thisWeek:
            let dow = (cal.component(.weekday, from: today) + 5) % 7
            let start = cal.date(byAdding: .day, value: -dow, to: today) ?? today
            return (start, today)
        case .lastWeek:
            let dow = (cal.component(.weekday, from: today) + 5) % 7
            let thisStart = cal.date(byAdding: .day, value: -dow, to: today) ?? today
            let lastEnd = cal.date(byAdding: .day, value: -1, to: thisStart) ?? thisStart
            let lastStart = cal.date(byAdding: .day, value: -6, to: lastEnd) ?? lastEnd
            return (lastStart, lastEnd)
        case .month(let ym):
            guard let d = DateFormatter.monthParser.date(from: ym) else {
                return (earliest, latest)
            }
            let start = cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
            let end = cal.date(byAdding: .month, value: 1, to: start) ?? start
            return (start, cal.date(byAdding: .day, value: -1, to: end) ?? start)
        case .custom(let f, let t):
            guard let fd = parseYMD(f), let td = parseYMD(t) else { return (earliest, latest) }
            return (min(fd, td), max(fd, td))
        }
    }

    func run() -> DashboardSnapshot? {
        guard let win = window() else { return nil }
        let fromStr = ymdStr(win.from)
        let toStr = ymdStr(win.to)
        let inRange = data.daily.filter { $0.period >= fromStr && $0.period <= toStr }
        let byDate = Dictionary(inRange.map { ($0.period, $0) }, uniquingKeysWith: { a, _ in a })

        var rows: [DayDatum] = []
        var modelAgg:
            [String: (
                tokens: Double, cost: Double, input: Double, output: Double, cacheRead: Double,
                days: Set<String>
            )] = [:]
        var dowTokens = [Double](repeating: 0, count: 7)
        var dowCost = [Double](repeating: 0, count: 7)
        var hourTok = [Double](repeating: 0, count: 24)
        var hourCost = [Double](repeating: 0, count: 24)
        var hourlyUnattributed = UsageAmount()
        var pathUnattributed = UsageAmount()
        var unfilterableModelCost = 0.0
        var projAgg: [String: RepoAccum] = [:]

        var cursor = win.from
        while cursor <= win.to {
            let key = ymdStr(cursor)
            var datum = DayDatum(id: key, date: cursor, label: String(key.dropFirst(5)))
            if let day = byDate[key] {
                let useProjectTotal = canonicalSourceCount(day) == 1
                var canonicalProjects: [ProjectAttributionKey: UsageAmount] = [:]
                for (src, models) in day.bySource ?? [:]
                where selectedSources.contains(src) {
                    let sourceTokenModels: Set<String> = Set(
                        models.compactMap { row -> String? in
                            guard !DashboardComputation.isUnattributedCost(row), row.tokens > 0
                            else { return nil }
                            return row.modelName ?? "unknown"
                        })
                    let selectedSourceModels = sourceTokenModels.intersection(selectedModels)
                    let includeUnattributedCost =
                        fullModelScope
                        || (!sourceTokenModels.isEmpty
                            && sourceTokenModels.isSubset(of: selectedModels))
                    for m in models {
                        let unattributedCost = DashboardComputation.isUnattributedCost(m)
                        if unattributedCost, !includeUnattributedCost {
                            if !selectedSourceModels.isEmpty {
                                unfilterableModelCost += m.cost ?? 0
                            }
                            continue
                        }
                        let name =
                            unattributedCost
                            ? DashboardComputation.unattributedCostModel
                            : (m.modelName ?? "unknown")
                        guard unattributedCost || selectedModels.contains(name) else { continue }
                        let attributionKey = ProjectAttributionKey(source: src, model: name)
                        guard
                            let projShare = projectShare(
                                day, key: attributionKey, useProjectTotal: useProjectTotal)
                        else {
                            pathUnattributed.tokens += m.tokens
                            pathUnattributed.cost += m.cost ?? 0
                            continue
                        }
                        let tokens = m.tokens * projShare.tokens
                        let cost = (m.cost ?? 0) * projShare.cost
                        guard tokens > 0 || cost > 0 else { continue }
                        datum.input += (m.inputTokens ?? 0) * projShare.tokens
                        datum.output += (m.outputTokens ?? 0) * projShare.tokens
                        datum.cacheCreate += (m.cacheCreationTokens ?? 0) * projShare.tokens
                        datum.cacheRead += (m.cacheReadTokens ?? 0) * projShare.tokens
                        datum.cost += cost
                        if tokens > 0 { datum.byModel[name, default: 0] += tokens }
                        datum.bySource[src, default: 0] += tokens
                        var agg = modelAgg[name] ?? (0, 0, 0, 0, 0, [])
                        agg.tokens += tokens
                        agg.cost += cost
                        agg.input += (m.inputTokens ?? 0) * projShare.tokens
                        agg.output += (m.outputTokens ?? 0) * projShare.tokens
                        agg.cacheRead += (m.cacheReadTokens ?? 0) * projShare.tokens
                        agg.days.insert(key)
                        modelAgg[name] = agg
                        canonicalProjects[attributionKey, default: UsageAmount()].tokens += tokens
                        canonicalProjects[attributionKey, default: UsageAmount()].cost += cost
                    }
                }
                let wd = (cal.component(.weekday, from: cursor) + 6) % 7
                dowTokens[wd] += datum.tokens
                dowCost[wd] += datum.cost
                let hourly = allocateHours(day, targets: canonicalProjects)
                for index in 0..<24 {
                    hourTok[index] += hourly.tokens[index]
                    hourCost[index] += hourly.cost[index]
                }
                hourlyUnattributed.tokens += hourly.unattributed.tokens
                hourlyUnattributed.cost += hourly.unattributed.cost
                let attributed = projectAllocations(day, canonical: canonicalProjects)
                for allocation in attributed.projects {
                    let p = allocation.project
                    let repository = DashboardComputation.repositoryIdentity(p)
                    let folder = DashboardComputation.folderIdentity(p, repository: repository)
                    var repositoryAccum =
                        projAgg[repository.id]
                        ?? RepoAccum(name: repository.name, url: repository.url)
                    var folderAccum =
                        repositoryAccum.folders[folder.id]
                        ?? ProjAccum(
                            name: folder.name, path: folder.path,
                            machineName: folder.machineName, machineID: folder.machineID)
                    let scale = projectScale(
                        p, targetTokens: allocation.amount.tokens,
                        targetCost: allocation.amount.cost)
                    if ProjAccum.hasTokenedChat(p), scale.rawTokens == 0, scale.rawCost == 0 {
                        folderAccum.addFallback(allocation.amount, period: key)
                    } else {
                        folderAccum.absorb(
                            p, period: key, scale: scale,
                            include: { self.pathInScope($0.path ?? self.knownPath(p)) })
                    }
                    repositoryAccum.folders[folder.id] = folderAccum
                    projAgg[repository.id] = repositoryAccum
                }
                if attributed.unattributed.tokens > 0 || attributed.unattributed.cost > 0 {
                    var repositoryAccum =
                        projAgg["unattributed"]
                        ?? RepoAccum(name: "Unattributed", url: "")
                    var folderAccum =
                        repositoryAccum.folders["folder:unattributed"]
                        ?? ProjAccum(
                            name: "Unattributed", path: "", machineName: "", machineID: "")
                    folderAccum.addFallback(attributed.unattributed, period: key)
                    repositoryAccum.folders["folder:unattributed"] = folderAccum
                    projAgg["unattributed"] = repositoryAccum
                }
            }
            rows.append(datum)
            cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? win.to.addingTimeInterval(1)
            if cursor <= win.from { break }
        }

        var snapshot = DashboardSnapshot()
        snapshot.series = rows

        let totalCost = modelAgg.values.reduce(0) { $0 + $1.cost }
        let totalModelTokens = modelAgg.values.reduce(0) { $0 + $1.tokens }
        var totals = modelAgg.map { name, a in
            ModelTotal(
                id: name, model: name, tokens: a.tokens, cost: a.cost, input: a.input,
                output: a.output, cacheRead: a.cacheRead, days: a.days.count,
                share: totalCost > 0 ? a.cost / totalCost : 0,
                tokenShare: totalModelTokens > 0 ? a.tokens / totalModelTokens : 0)
        }
        totals.sort {
            DashboardComputation.modelTotalLess(
                $0, $1, column: sortColumn, ascending: sortAscending)
        }
        snapshot.modelTotals = totals

        let wdLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        snapshot.dow = (0..<7).map {
            DOWDatum(label: wdLabels[$0], tokens: dowTokens[$0], cost: dowCost[$0])
        }
        snapshot.hourlyAll = (0..<24).map {
            HourDatum(id: $0, hour: $0, tokens: hourTok[$0], cost: hourCost[$0])
        }
        snapshot.hourlyUnattributedTokens = hourlyUnattributed.tokens
        snapshot.hourlyUnattributedCost = hourlyUnattributed.cost
        snapshot.pathUnattributedTokens = pathUnattributed.tokens
        snapshot.pathUnattributedCost = pathUnattributed.cost
        snapshot.modelUnfilterableCost = unfilterableModelCost

        let totalTokens = rows.reduce(0) { $0 + $1.tokens }
        let activeDays = Set(rows.filter { $0.tokens > 0 || $0.cost > 0 }.map(\.id))
        snapshot.projectTree = buildProjectTree(
            projAgg, targetTokens: totalTokens, targetCost: totalCost, targetDays: activeDays)
        snapshot.projects = snapshot.projectTree.map {
            ProjectAgg(id: $0.id, name: $0.name, tokens: $0.tokens, cost: $0.cost, share: $0.share)
        }
        .sorted { $0.tokens > $1.tokens }

        snapshot.kpis = kpis(rows: rows, totalCost: totalCost, totals: totals)
        snapshot.meta = meta(from: fromStr, to: toStr, series: rows, totals: totals)
        snapshot.chartData = chartData(
            series: rows, dow: snapshot.dow, hourly: snapshot.hourlyAll,
            projects: snapshot.projects)
        return snapshot
    }

    private func rawUsage(_ p: DashUsage.Project, scoped: Bool) -> (tokens: Double, cost: Double) {
        guard ProjAccum.hasTokenedChat(p) else {
            guard !scoped || pathInScope(knownPath(p)) else { return (0, 0) }
            return (p.tokens ?? 0, p.cost ?? 0)
        }
        let chats = (p.chats ?? []) + (p.worktrees ?? []).flatMap { $0.chats ?? [] }
        let fallback = knownPath(p)
        let kept = chats.filter {
            scoped ? chatInScope($0, fallback: fallback) : chatVisible($0.source)
        }
        return kept.reduce(into: (0.0, 0.0)) {
            $0.0 += $1.tokens ?? 0
            $0.1 += $1.cost ?? 0
        }
    }

    private func projectShare(
        _ day: DashUsage.Day, key: ProjectAttributionKey, useProjectTotal: Bool
    ) -> UsageAmount? {
        guard !selectedPaths.isEmpty else { return UsageAmount(tokens: 1, cost: 1) }
        let useSourceTotal = sourceHasSingleCanonicalModel(day, key: key)
        var all = UsageAmount()
        var mine = UsageAmount()
        for p in day.projects ?? [] {
            let raw = rawProjectAmount(
                p, key: key, useSourceTotal: useSourceTotal,
                useProjectTotal: useProjectTotal, scoped: false)
            let scoped = rawProjectAmount(
                p, key: key, useSourceTotal: useSourceTotal,
                useProjectTotal: useProjectTotal, scoped: true)
            all.tokens += raw.tokens
            all.cost += raw.cost
            mine.tokens += scoped.tokens
            mine.cost += scoped.cost
        }
        guard all.tokens > 0 || all.cost > 0 else { return nil }
        return UsageAmount(
            tokens: normalizedPart(
                mine.tokens, alternate: mine.cost, rawTotal: all.tokens,
                rawAlternateTotal: all.cost, target: 1),
            cost: normalizedPart(
                mine.cost, alternate: mine.tokens, rawTotal: all.cost,
                rawAlternateTotal: all.tokens, target: 1)
        )
    }

    private func projectAllocations(
        _ day: DashUsage.Day, canonical: [ProjectAttributionKey: UsageAmount]
    ) -> (projects: [ProjectAllocation], unattributed: UsageAmount) {
        let projects = day.projects ?? []
        var amounts = projects.map { ProjectAllocation(project: $0) }
        var unattributed = UsageAmount()
        let useProjectTotal = canonicalSourceCount(day) == 1
        for (key, target) in canonical {
            let useSourceTotal = sourceHasSingleCanonicalModel(day, key: key)
            let raw = projects.map {
                rawProjectAmount(
                    $0, key: key, useSourceTotal: useSourceTotal,
                    useProjectTotal: useProjectTotal, scoped: true)
            }
            let rawTokens = raw.reduce(0) { $0 + $1.tokens }
            let rawCost = raw.reduce(0) { $0 + $1.cost }
            guard rawTokens > 0 || rawCost > 0 else {
                unattributed.tokens += target.tokens
                unattributed.cost += target.cost
                continue
            }
            for index in projects.indices {
                amounts[index].amount.tokens += normalizedPart(
                    raw[index].tokens, alternate: raw[index].cost, rawTotal: rawTokens,
                    rawAlternateTotal: rawCost, target: target.tokens)
                amounts[index].amount.cost += normalizedPart(
                    raw[index].cost, alternate: raw[index].tokens, rawTotal: rawCost,
                    rawAlternateTotal: rawTokens, target: target.cost)
            }
        }
        return (
            amounts.filter { $0.amount.tokens > 0 || $0.amount.cost > 0 }, unattributed
        )
    }

    private func rawProjectAmount(
        _ project: DashUsage.Project, key: ProjectAttributionKey, useSourceTotal: Bool,
        useProjectTotal: Bool, scoped: Bool
    ) -> UsageAmount {
        if let breakdown = project.bySource?[key.source] {
            guard
                let amount = DashboardComputation.sourceAmount(
                    breakdown, model: key.model, useSourceTotal: useSourceTotal)
            else { return UsageAmount() }
            let scope = projectScope(
                project, source: key.source, allowChatScope: useSourceTotal, scoped: scoped)
            return UsageAmount(
                tokens: amount.tokens * scope.tokens,
                cost: amount.cost * scope.cost)
        }
        if let bySource = project.bySource, !bySource.isEmpty { return UsageAmount() }

        guard fullModelScope || useSourceTotal else { return UsageAmount() }
        let chats = (project.chats ?? []) + (project.worktrees ?? []).flatMap { $0.chats ?? [] }
        let sourceChats = chats.filter { $0.source == key.source }
        if !sourceChats.isEmpty {
            let scopedChats =
                scoped
                ? sourceChats.filter { pathInScope($0.path ?? knownPath(project)) }
                : sourceChats
            return scopedChats.reduce(into: UsageAmount()) {
                $0.tokens += $1.tokens ?? 0
                $0.cost += $1.cost ?? 0
            }
        }

        guard !ProjAccum.hasTokenedChat(project), useProjectTotal,
            !scoped || pathInScope(knownPath(project))
        else { return UsageAmount() }
        return UsageAmount(tokens: project.tokens ?? 0, cost: project.cost ?? 0)
    }

    private func canonicalSourceCount(_ day: DashUsage.Day) -> Int {
        (day.bySource ?? [:]).values.filter { !$0.isEmpty }.count
    }

    private func sourceHasSingleCanonicalModel(
        _ day: DashUsage.Day, key: ProjectAttributionKey
    ) -> Bool {
        let tokenModels = Set(
            (day.bySource?[key.source] ?? []).compactMap { row -> String? in
                guard !DashboardComputation.isUnattributedCost(row), row.tokens > 0 else {
                    return nil
                }
                return row.modelName ?? "unknown"
            })
        return key.model == DashboardComputation.unattributedCostModel
            || (tokenModels.count == 1 && tokenModels.contains(key.model))
    }

    private func projectScope(
        _ project: DashUsage.Project, source: String, allowChatScope: Bool, scoped: Bool
    ) -> UsageAmount {
        guard scoped, !selectedPaths.isEmpty else { return UsageAmount(tokens: 1, cost: 1) }
        if pathInScope(knownPath(project)) { return UsageAmount(tokens: 1, cost: 1) }
        guard allowChatScope else { return UsageAmount() }
        let chats = (project.chats ?? []) + (project.worktrees ?? []).flatMap { $0.chats ?? [] }
        let sourceChats = chats.filter { $0.source == source }
        let all = sourceChats.reduce(into: UsageAmount()) {
            $0.tokens += $1.tokens ?? 0
            $0.cost += $1.cost ?? 0
        }
        let matching = sourceChats.filter { pathInScope($0.path ?? knownPath(project)) }
        let mine = matching.reduce(into: UsageAmount()) {
            $0.tokens += $1.tokens ?? 0
            $0.cost += $1.cost ?? 0
        }
        return UsageAmount(
            tokens: normalizedPart(
                mine.tokens, alternate: mine.cost, rawTotal: all.tokens,
                rawAlternateTotal: all.cost, target: 1),
            cost: normalizedPart(
                mine.cost, alternate: mine.tokens, rawTotal: all.cost,
                rawAlternateTotal: all.tokens, target: 1))
    }

    private var hourlyFiltersAreUnfiltered: Bool {
        selectedSources == Set(allSources.map(\.id)) && selectedModels == Set(allModels)
            && selectedPaths.isEmpty
    }

    private func allocateHours(
        _ day: DashUsage.Day, targets: [ProjectAttributionKey: UsageAmount]
    ) -> HourlyAllocation {
        var result = HourlyAllocation()
        let hours = Array((day.hours ?? []).prefix(24))
        let total = targets.values.reduce(into: UsageAmount()) {
            $0.tokens += $1.tokens
            $0.cost += $1.cost
        }
        guard total.tokens > 0 || total.cost > 0 else { return result }

        func add(
            target: UsageAmount, rawTokens: [Double], rawCost: [Double],
            to result: inout HourlyAllocation
        ) {
            let rawTokenTotal = rawTokens.reduce(0, +)
            let rawCostTotal = rawCost.reduce(0, +)
            guard rawTokenTotal > 0 || rawCostTotal > 0 else {
                result.unattributed.tokens += target.tokens
                result.unattributed.cost += target.cost
                return
            }
            for index in 0..<24 {
                result.tokens[index] += normalizedPart(
                    rawTokens[index], alternate: rawCost[index], rawTotal: rawTokenTotal,
                    rawAlternateTotal: rawCostTotal, target: target.tokens)
                result.cost[index] += normalizedPart(
                    rawCost[index], alternate: rawTokens[index], rawTotal: rawCostTotal,
                    rawAlternateTotal: rawTokenTotal, target: target.cost)
            }
        }

        if !selectedPaths.isEmpty {
            guard hours.contains(where: { $0.byPath != nil }) else {
                result.unattributed = total
                return result
            }
            for (key, target) in targets {
                let useSourceTotal = sourceHasSingleCanonicalModel(day, key: key)
                var rawTokens = [Double](repeating: 0, count: 24)
                var rawCost = [Double](repeating: 0, count: 24)
                for (index, hour) in hours.enumerated() {
                    for (path, breakdown) in hour.byPath ?? [:] where pathInScope(path) {
                        guard let source = breakdown.bySource?[key.source],
                            let amount = DashboardComputation.sourceAmount(
                                source, model: key.model, useSourceTotal: useSourceTotal)
                        else { continue }
                        rawTokens[index] += amount.tokens
                        rawCost[index] += amount.cost
                    }
                }
                add(
                    target: target, rawTokens: rawTokens, rawCost: rawCost,
                    to: &result)
            }
            return result
        }

        if hours.contains(where: { $0.bySource != nil }) {
            for (key, target) in targets {
                let useSourceTotal = sourceHasSingleCanonicalModel(day, key: key)
                var rawTokens = [Double](repeating: 0, count: 24)
                var rawCost = [Double](repeating: 0, count: 24)
                for (index, hour) in hours.enumerated() {
                    guard let source = hour.bySource?[key.source],
                        let amount = DashboardComputation.sourceAmount(
                            source, model: key.model, useSourceTotal: useSourceTotal)
                    else { continue }
                    rawTokens[index] = amount.tokens
                    rawCost[index] = amount.cost
                }
                add(
                    target: target, rawTokens: rawTokens, rawCost: rawCost,
                    to: &result)
            }
            return result
        }

        guard hourlyFiltersAreUnfiltered else {
            result.unattributed = total
            return result
        }
        var rawTokens = [Double](repeating: 0, count: 24)
        var rawCost = [Double](repeating: 0, count: 24)
        for (index, hour) in hours.enumerated() {
            rawTokens[index] = hour.tokens ?? 0
            rawCost[index] = hour.cost ?? 0
        }
        add(target: total, rawTokens: rawTokens, rawCost: rawCost, to: &result)
        return result
    }

    private func projectScale(
        _ project: DashUsage.Project, targetTokens: Double, targetCost: Double
    ) -> DayScale {
        let raw = rawUsage(project, scoped: true)
        return DayScale(
            rawTokens: raw.tokens, rawCost: raw.cost, dayTokens: targetTokens,
            dayCost: targetCost)
    }

    private func buildProjectTree(
        _ agg: [String: RepoAccum], targetTokens: Double, targetCost: Double,
        targetDays: Set<String>
    ) -> [ProjTreeRow] {
        let visible = { (c: ChatAcc) in c.source.isEmpty || self.selectedSources.contains(c.source)
        }
        func chatRow(_ id: String, _ a: ChatAcc) -> ProjChat {
            let title =
                a.title.isEmpty
                ? (id.isEmpty ? "Untitled chat" : "Chat \(String(id.prefix(8)))") : a.title
            return ProjChat(
                id: id, title: title, tokens: a.tokens, cost: a.cost, daySet: a.days,
                dur: a.dur, lastActive: a.lastActive, source: a.source)
        }
        func chatRows(_ map: [String: ChatAcc]) -> [ProjChat] {
            map.filter { visible($0.value) }.map { chatRow($0.key, $0.value) }.sorted {
                ($0.tokens, $1.id) > ($1.tokens, $0.id)
            }
        }
        func daysOf(_ chats: [ProjChat]) -> Set<String> {
            chats.reduce(into: Set<String>()) { $0.formUnion($1.daySet) }
        }
        func folderRow(_ id: String, _ accum: ProjAccum) -> ProjFolder? {
            let mainChats = chatRows(accum.main)
            let worktrees: [ProjWorktree] = accum.wts.compactMap { worktreeName, chatsAccum in
                let chats = chatRows(chatsAccum)
                guard !chats.isEmpty else { return nil }
                return ProjWorktree(
                    id: "\(id)|worktree:\(worktreeName)", name: worktreeName,
                    tokens: chats.reduce(0) { $0 + $1.tokens },
                    cost: chats.reduce(0) { $0 + $1.cost }, days: daysOf(chats).count,
                    dur: chats.reduce(0) { $0 + $1.dur },
                    lastActive: chats.map(\.lastActive).max() ?? "", chats: chats)
            }
            .sorted { ($0.tokens, $1.name) > ($1.tokens, $0.name) }
            guard !mainChats.isEmpty || !worktrees.isEmpty || accum.fallbackTokens > 0 else {
                return nil
            }
            let allDays =
                daysOf(mainChats + worktrees.flatMap(\.chats)).union(accum.fallbackDays)
            let lastActive =
                (mainChats.map(\.lastActive) + worktrees.map(\.lastActive)
                + accum.fallbackDays.sorted()).max() ?? ""
            return ProjFolder(
                id: id, name: accum.name, path: accum.path, machineName: accum.machineName,
                machineID: accum.machineID,
                tokens: mainChats.reduce(0) { $0 + $1.tokens }
                    + worktrees.reduce(0) { $0 + $1.tokens } + accum.fallbackTokens,
                cost: mainChats.reduce(0) { $0 + $1.cost }
                    + worktrees.reduce(0) { $0 + $1.cost } + accum.fallbackCost,
                daySet: allDays,
                dur: mainChats.reduce(0) { $0 + $1.dur }
                    + worktrees.reduce(0) { $0 + $1.dur },
                lastActive: lastActive, chats: mainChats, worktrees: worktrees)
        }

        var rows: [ProjTreeRow] = []
        for (repositoryID, accum) in agg {
            let folders = accum.folders.compactMap(folderRow)
            guard !folders.isEmpty else { continue }
            let allDays = folders.reduce(into: Set<String>()) { $0.formUnion($1.daySet) }
            rows.append(
                ProjTreeRow(
                    id: "repo:\(repositoryID)", name: accum.name, repositoryURL: accum.url,
                    tokens: folders.reduce(0) { $0 + $1.tokens },
                    cost: folders.reduce(0) { $0 + $1.cost }, days: allDays.count,
                    dur: folders.reduce(0) { $0 + $1.dur },
                    lastActive: folders.map(\.lastActive).max() ?? "", folders: folders))
        }

        rows = normalizeProjectRows(
            rows, targetTokens: targetTokens, targetCost: targetCost, targetDays: targetDays)
        return DashboardComputation.sortTree(
            rows, key: projSortKey, ascending: projSortAscending)
    }

    private func normalizeProjectRows(
        _ rows: [ProjTreeRow], targetTokens: Double, targetCost: Double,
        targetDays: Set<String>
    ) -> [ProjTreeRow] {
        guard targetTokens > 0 || targetCost > 0 else { return [] }
        let rawTokens = rows.reduce(0) { $0 + $1.tokens }
        let rawCost = rows.reduce(0) { $0 + $1.cost }
        let missingTokens = max(targetTokens - rawTokens, 0)
        let missingCost = max(targetCost - rawCost, 0)
        var completed = rows
        if missingTokens > 0.000_001 || missingCost > 0.000_001 {
            completed = addUnattributed(
                to: completed, tokens: missingTokens, cost: missingCost, days: targetDays)
        }
        func chat(_ row: ProjChat) -> ProjChat {
            return ProjChat(
                id: row.id, title: row.title, tokens: row.tokens, cost: row.cost,
                share: targetCost > 0 ? row.cost / targetCost : 0, daySet: row.daySet,
                dur: row.dur, lastActive: row.lastActive, source: row.source)
        }
        func worktree(_ row: ProjWorktree) -> ProjWorktree {
            return ProjWorktree(
                id: row.id, name: row.name, tokens: row.tokens, cost: row.cost,
                share: targetCost > 0 ? row.cost / targetCost : 0, days: row.days, dur: row.dur,
                lastActive: row.lastActive, chats: row.chats.map(chat))
        }
        func folder(_ row: ProjFolder) -> ProjFolder {
            return ProjFolder(
                id: row.id, name: row.name, path: row.path, machineName: row.machineName,
                machineID: row.machineID, tokens: row.tokens, cost: row.cost,
                share: targetCost > 0 ? row.cost / targetCost : 0, daySet: row.daySet,
                dur: row.dur, lastActive: row.lastActive, chats: row.chats.map(chat),
                worktrees: row.worktrees.map(worktree))
        }
        return completed.map { row in
            return ProjTreeRow(
                id: row.id, name: row.name, repositoryURL: row.repositoryURL, tokens: row.tokens,
                cost: row.cost, share: targetCost > 0 ? row.cost / targetCost : 0,
                days: row.days, dur: row.dur,
                lastActive: row.lastActive, folders: row.folders.map(folder))
        }
    }

    private func addUnattributed(
        to rows: [ProjTreeRow], tokens: Double, cost: Double, days: Set<String>
    ) -> [ProjTreeRow] {
        var next = rows
        let id = "repo:unattributed"
        let folderID = "folder:unattributed"
        let folder = ProjFolder(
            id: folderID, name: "Unattributed", path: "", machineName: "", machineID: "",
            tokens: tokens, cost: cost, daySet: days, dur: 0, lastActive: days.max() ?? "",
            chats: [], worktrees: [])
        guard let rowIndex = next.firstIndex(where: { $0.id == id }) else {
            next.append(
                ProjTreeRow(
                    id: id, name: "Unattributed", repositoryURL: "", tokens: tokens, cost: cost,
                    days: days.count, dur: 0, lastActive: days.max() ?? "", folders: [folder]))
            return next
        }
        let row = next[rowIndex]
        var folders = row.folders
        if let folderIndex = folders.firstIndex(where: { $0.id == folderID }) {
            let current = folders[folderIndex]
            let allDays = current.daySet.union(days)
            folders[folderIndex] = ProjFolder(
                id: folderID, name: current.name, path: current.path,
                machineName: current.machineName, machineID: current.machineID,
                tokens: current.tokens + tokens, cost: current.cost + cost, daySet: allDays,
                dur: current.dur, lastActive: max(current.lastActive, days.max() ?? ""),
                chats: current.chats, worktrees: current.worktrees)
        } else {
            folders.append(folder)
        }
        let allDays = folders.reduce(into: Set<String>()) { $0.formUnion($1.daySet) }
        next[rowIndex] = ProjTreeRow(
            id: row.id, name: row.name, repositoryURL: row.repositoryURL,
            tokens: row.tokens + tokens, cost: row.cost + cost, days: allDays.count, dur: row.dur,
            lastActive: max(row.lastActive, days.max() ?? ""), folders: folders)
        return next
    }

    private func kpis(rows: [DayDatum], totalCost: Double, totals: [ModelTotal]) -> [KPI] {
        let totalTokens = rows.reduce(0) { $0 + $1.tokens }
        let active = rows.filter { $0.tokens > 0 }
        let busiest = rows.max { $0.tokens < $1.tokens }
        let cacheRead = rows.reduce(0) { $0 + $1.cacheRead }
        let input = rows.reduce(0) { $0 + $1.input }
        let output = rows.reduce(0) { $0 + $1.output }
        let cacheCreate = rows.reduce(0) { $0 + $1.cacheCreate }
        let cacheRate = (cacheRead + input) > 0 ? cacheRead / (cacheRead + input) : 0
        let top = totals.filter {
            $0.model != DashboardComputation.unattributedCostModel && $0.tokens > 0
        }.max { $0.tokens < $1.tokens }

        func share(_ v: Double) -> String {
            "\(DashFmt.pct(totalTokens > 0 ? v / totalTokens : 0)) of tokens"
        }

        var out: [KPI] = [
            KPI(
                label: "Total tokens", value: DashFmt.tokens(totalTokens),
                sub: "\(DashFmt.usd(totalCost)) · \(active.count) active days", hot: true,
                sensitiveSub: true, usageValue: true),
            KPI(
                label: "Total cost", value: DashFmt.usd(totalCost),
                sub: "\(DashFmt.tokensFull(totalTokens)) tokens", sensitiveValue: true,
                usageSub: true),
            KPI(
                label: "Input", value: DashFmt.tokens(input), sub: share(input),
                usageValue: true),
            KPI(
                label: "Output", value: DashFmt.tokens(output), sub: share(output),
                usageValue: true),
            KPI(
                label: "Cache write", value: DashFmt.tokens(cacheCreate), sub: share(cacheCreate),
                usageValue: true),
            KPI(
                label: "Cache read", value: DashFmt.tokens(cacheRead), sub: share(cacheRead),
                usageValue: true),
        ]
        if let busiest {
            out.append(
                KPI(
                    label: "Busiest day", value: busiest.label,
                    sub: "\(DashFmt.tokens(busiest.tokens)) · \(DashFmt.usd(busiest.cost))",
                    sensitiveSub: true, usageSub: true))
        }
        if !active.isEmpty {
            out.append(
                KPI(
                    label: "Daily average",
                    value: DashFmt.tokens(totalTokens / Double(active.count)),
                    sub: "\(DashFmt.usd(totalCost / Double(active.count))) / active day",
                    sensitiveSub: true, usageValue: true))
        }
        out.append(
            KPI(
                label: "Cache hit rate", value: DashFmt.pct(cacheRate),
                sub: "\(DashFmt.tokens(cacheRead)) cached reads", usageSub: true))
        if let top {
            out.append(
                KPI(
                    label: "Top model", value: DashboardComputation.modelLabel(top.model),
                    sub: "\(DashFmt.tokens(top.tokens)) · \(DashFmt.pct(top.tokenShare)) of tokens",
                    usageSub: true))
        }
        return out
    }

    private func meta(
        from: String, to: String, series: [DayDatum], totals: [ModelTotal]
    ) -> MetaLine {
        var m = MetaLine()
        if let gen = data.generatedAt, let d = EdithDate.parseISO(gen) {
            m.updated = d.formatted(date: .abbreviated, time: .shortened)
        }
        m.totalCost = DashFmt.usd(series.reduce(0) { $0 + $1.cost })
        m.totalTokens = DashFmt.tokens(series.reduce(0) { $0 + $1.tokens })
        m.activeDays = series.filter { $0.tokens > 0 }.count
        m.modelCount = totals.filter { $0.tokens > 0 }.count
        m.sourceLabels = allSources.filter { selectedSources.contains($0.id) }.map(\.label).joined(
            separator: " + ")
        m.windowFrom = String(from.dropFirst(5))
        m.windowTo = String(to.dropFirst(5))
        m.schema = data.schemaVersion ?? 0
        m.sessions = data.sessions?.count ?? 0
        return m
    }

    private struct StackBucket {
        let id: String
        let label: String
        var input = 0.0
        var output = 0.0
        var cacheCreate = 0.0
        var cacheRead = 0.0
        var byModel: [String: Double] = [:]
        var bySource: [String: Double] = [:]
    }

    private func stackBuckets(_ series: [DayDatum]) -> [StackBucket] {
        guard series.count > DashboardComputation.weeklyBucketThresholdDays else {
            return series.map { d in
                var bucket = StackBucket(id: d.id, label: d.label)
                bucket.input = d.input
                bucket.output = d.output
                bucket.cacheCreate = d.cacheCreate
                bucket.cacheRead = d.cacheRead
                bucket.byModel = d.byModel
                bucket.bySource = d.bySource
                return bucket
            }
        }
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = cal.timeZone
        var order: [String] = []
        var buckets: [String: StackBucket] = [:]
        for d in series {
            let comps = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d.date)
            let key = String(
                format: "week:%04d-W%02d", comps.yearForWeekOfYear ?? 0, comps.weekOfYear ?? 0)
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = StackBucket(id: key, label: d.label)
            }
            guard var bucket = buckets[key] else { continue }
            bucket.input += d.input
            bucket.output += d.output
            bucket.cacheCreate += d.cacheCreate
            bucket.cacheRead += d.cacheRead
            for (name, value) in d.byModel {
                bucket.byModel[name, default: 0] += value
            }
            for (name, value) in d.bySource {
                bucket.bySource[name, default: 0] += value
            }
            buckets[key] = bucket
        }
        return order.compactMap { buckets[$0] }
    }

    private func stackedSeries(
        _ buckets: [StackBucket], values: KeyPath<StackBucket, [String: Double]>,
        label: (String) -> String
    ) -> [StackDatum] {
        var totals: [String: Double] = [:]
        for bucket in buckets {
            for (name, value) in bucket[keyPath: values] {
                totals[name, default: 0] += value
            }
        }
        let ranked = totals.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }.map(\.key)
        let kept = Array(ranked.prefix(DashboardComputation.stackedSeriesLimit))
        let keptSet = Set(kept)
        var out: [StackDatum] = []
        for bucket in buckets {
            let seriesValues = bucket[keyPath: values]
            for name in kept {
                guard let value = seriesValues[name] else { continue }
                out.append(
                    StackDatum(
                        id: "\(bucket.id)-\(name)", x: bucket.label,
                        series: label(name), value: value))
            }
            let rest = seriesValues.reduce(0.0) {
                keptSet.contains($1.key) ? $0 : $0 + $1.value
            }
            if rest > 0 {
                out.append(
                    StackDatum(
                        id: "\(bucket.id)-other", x: bucket.label, series: "Other", value: rest))
            }
        }
        return out
    }

    private func chartData(
        series: [DayDatum], dow: [DOWDatum], hourly: [HourDatum], projects: [ProjectAgg]
    ) -> DashChartData {
        var next = DashChartData()
        next.daily = series.map {
            ComboPoint(id: $0.id, label: $0.label, tokens: $0.tokens, cost: $0.cost)
        }
        next.dow = dow.map {
            ComboPoint(id: $0.label, label: $0.label, tokens: $0.tokens, cost: $0.cost)
        }
        next.hourly = hourly.map {
            ComboPoint(
                id: "\($0.hour)", label: String(format: "%02d", $0.hour), tokens: $0.tokens,
                cost: $0.cost)
        }
        var projectPoints = projects.prefix(15).map {
            ComboPoint(id: $0.id, label: $0.name, tokens: $0.tokens, cost: $0.cost)
        }
        let rest = projects.dropFirst(15)
        if !rest.isEmpty {
            projectPoints.append(
                ComboPoint(
                    id: "__others", label: "others (\(rest.count))",
                    tokens: rest.reduce(0) { $0 + $1.tokens },
                    cost: rest.reduce(0) { $0 + $1.cost }))
        }
        next.project = projectPoints
        let buckets = stackBuckets(series)
        next.tokenMix = buckets.flatMap { d in
            [
                StackDatum(id: "\(d.id)-in", x: d.label, series: "input", value: d.input),
                StackDatum(id: "\(d.id)-out", x: d.label, series: "output", value: d.output),
                StackDatum(
                    id: "\(d.id)-cc", x: d.label, series: "cache write", value: d.cacheCreate),
                StackDatum(id: "\(d.id)-cr", x: d.label, series: "cache read", value: d.cacheRead),
            ]
        }
        next.modelTime = stackedSeries(buckets, values: \.byModel, label: DashFmt.shortModel)
        next.source = stackedSeries(buckets, values: \.bySource, label: sourceLabel)
        let costs = calendarDays.map(\.cost).filter { $0 > 0 }.sorted()
        next.heatCuts =
            costs.isEmpty
            ? [0, 0, 0]
            : [costs[costs.count / 4], costs[costs.count / 2], costs[costs.count * 3 / 4]]
        return next
    }
}
