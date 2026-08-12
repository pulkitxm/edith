import EdithKit
import Observation
import SwiftUI

enum DashPalette {
    static let lightCat = [
        "#d97757", "#2f4858", "#c89b3c", "#6a8d73", "#8c5e58",
        "#4a6b8a", "#b07156", "#7d6b9e", "#9aa05c", "#5f7a7a",
    ]
    static let darkCat = [
        "#e08a6a", "#7ea7be", "#d8b04f", "#85ab8e", "#b07d74",
        "#6f97bd", "#c98a6c", "#9c8bc0", "#b3bb6e", "#7fa0a0",
    ]
    static let other = "#b8b0a4"

    static let lightColors = lightCat.map(color)
    static let darkColors = darkCat.map(color)
    static let otherColor = color(other)
    static let slateLight = color("#2f4858")
    static let slateDark = color("#7ea7be")

    static func cat(_ dark: Bool) -> [String] { dark ? darkCat : lightCat }
    static func slate(_ dark: Bool) -> Color { dark ? slateDark : slateLight }

    static func categorical(_ index: Int, dark: Bool) -> Color {
        let c = dark ? darkColors : lightColors
        return c[((index % c.count) + c.count) % c.count]
    }

    static func modelColor(_ index: Int?, dark: Bool) -> Color {
        guard let index else { return otherColor }
        return categorical(index, dark: dark)
    }

    static func sourceColor(_ index: Int?, dark: Bool) -> Color {
        guard let index else { return otherColor }
        return index == 0 ? slate(dark) : categorical(index - 1, dark: dark)
    }

    static let inputColor = { (dark: Bool) in slate(dark) }
    static func outputColor(_ dark: Bool) -> Color { categorical(0, dark: dark) }
    static let cacheCreateColor = color("#c89b3c")
    static let cacheReadColor = color("#6a8d73")

    static func color(_ hex: String) -> Color {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xff) / 255
        let g = Double((value >> 8) & 0xff) / 255
        let b = Double(value & 0xff) / 255
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

struct DashUsage: Decodable {
    let generatedAt: String?
    let schemaVersion: Int?
    let sources: [String]?
    let defaultSources: [String]?
    let sourceMeta: [String: Meta]?
    let totals: Totals?
    let machines: [Machine]?
    let daily: [Day]
    let sessions: [Session]?

    struct Meta: Decodable {
        let label: String?
        let tool: String?
        let machine: String?
        let machineID: String?
    }
    struct Totals: Decodable {
        let cost: Double?
        let tokens: Double?
    }
    struct Session: Decodable {
        let id: String?
        let source: String?
    }
    struct Machine: Decodable {
        let id: String?
        let collectedAt: String?
    }
    struct Day: Decodable {
        let period: String
        let bySource: [String: [Model]]?
        let projects: [Project]?
        let hours: [Hour]?
    }
    struct Model: Decodable {
        let modelName: String?
        let inputTokens: Double?
        let outputTokens: Double?
        let cacheCreationTokens: Double?
        let cacheReadTokens: Double?
        let cost: Double?
        var tokens: Double {
            (inputTokens ?? 0) + (outputTokens ?? 0) + (cacheCreationTokens ?? 0)
                + (cacheReadTokens ?? 0)
        }
    }
    struct Project: Decodable {
        let projectName: String?
        let repositoryID: String?
        let repositoryName: String?
        let repositoryURL: String?
        let folderName: String?
        let path: String?
        let machineName: String?
        let machineID: String?
        let tokens: Double?
        let cost: Double?
        let bySource: [String: SourceBreakdown]?
        let chats: [Chat]?
        let worktrees: [Worktree]?
    }
    struct SourceBreakdown: Decodable {
        let tokens: Double?
        let cost: Double?
        let byModel: [String: ProjectUsage]?
    }
    struct ProjectUsage: Decodable {
        let tokens: Double?
        let cost: Double?
    }
    struct Worktree: Decodable {
        let name: String?
        let tokens: Double?
        let cost: Double?
        let chats: [Chat]?
    }
    struct Chat: Decodable {
        let id: String?
        let path: String?
        let title: String?
        let tokens: Double?
        let cost: Double?
        let source: String?
        let firstTs: Double?
        let lastTs: Double?
    }
    struct Hour: Decodable {
        let tokens: Double?
        let cost: Double?
        let bySource: [String: SourceBreakdown]?
        let byPath: [String: PathBreakdown]?
    }
    struct PathBreakdown: Decodable {
        let tokens: Double?
        let cost: Double?
        let bySource: [String: SourceBreakdown]?
    }
}

enum DashRange: Equatable {
    case today, yesterday, thisWeek, lastWeek, all
    case cycle(String?)
    case month(String)
    case custom(String, String)
}

enum DashMetric: String { case tokens, cost }

struct DayDatum: Identifiable {
    let id: String
    let date: Date
    let label: String
    var input = 0.0
    var output = 0.0
    var cacheCreate = 0.0
    var cacheRead = 0.0
    var cost = 0.0
    var byModel: [String: Double] = [:]
    var bySource: [String: Double] = [:]
    var tokens: Double { input + output + cacheCreate + cacheRead }
}

struct ModelTotal: Identifiable {
    let id: String
    let model: String
    let tokens: Double
    let cost: Double
    let input: Double
    let output: Double
    let cacheRead: Double
    let days: Int
    var share = 0.0
    var tokenShare = 0.0
}

struct DOWDatum: Identifiable {
    let id = UUID()
    let label: String
    let tokens: Double
    let cost: Double
}

struct HourDatum: Identifiable {
    let id: Int
    let hour: Int
    let tokens: Double
    let cost: Double
}

struct ProjectPath: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let tokens: Double
}

struct MachineGroup: Identifiable, Equatable {
    static let localID = "local"

    let id: String
    let name: String
    let sourceIDs: [String]
    var agentNames: [String] = []

    var isLocal: Bool { id == Self.localID }

    var agentSummary: String { agentNames.joined(separator: ", ") }
}

struct ProjectAgg: Identifiable {
    let id: String
    let name: String
    let tokens: Double
    let cost: Double
    var share = 0.0
}

enum ProjSortKey: String, CaseIterable {
    case name, tokens, cost, share, days, dur, lastActive
}

func normalizedPart(
    _ value: Double, alternate: Double, rawTotal: Double, rawAlternateTotal: Double,
    target: Double
) -> Double {
    if rawTotal > 0 { return target * value / rawTotal }
    if rawAlternateTotal > 0 { return target * alternate / rawAlternateTotal }
    return 0
}

struct DayScale {
    var rawTokens = 0.0
    var rawCost = 0.0
    var dayTokens = 0.0
    var dayCost = 0.0

    func tokens(_ tokens: Double, _ cost: Double) -> Double {
        normalizedPart(
            tokens, alternate: cost, rawTotal: rawTokens, rawAlternateTotal: rawCost,
            target: dayTokens)
    }

    func cost(_ cost: Double, _ tokens: Double) -> Double {
        normalizedPart(
            cost, alternate: tokens, rawTotal: rawCost, rawAlternateTotal: rawTokens,
            target: dayCost)
    }
}

protocol ProjSortable {
    var sortName: String { get }
    var tokens: Double { get }
    var cost: Double { get }
    var share: Double { get }
    var days: Int { get }
    var dur: Double { get }
    var lastActive: String { get }
}

struct ProjChat: Identifiable, ProjSortable {
    let id: String
    let title: String
    let tokens: Double
    let cost: Double
    var share = 0.0
    let daySet: Set<String>
    let dur: Double
    let lastActive: String
    let source: String
    var days: Int { daySet.count }
    var sortName: String { title }
}

struct ProjWorktree: Identifiable, ProjSortable {
    let id: String
    let name: String
    let tokens: Double
    let cost: Double
    var share = 0.0
    let days: Int
    let dur: Double
    let lastActive: String
    var chats: [ProjChat]
    var sortName: String { name }
}

struct ProjFolder: Identifiable, ProjSortable {
    let id: String
    let name: String
    let path: String
    let machineName: String
    let machineID: String
    let tokens: Double
    let cost: Double
    var share = 0.0
    let daySet: Set<String>
    let dur: Double
    let lastActive: String
    var chats: [ProjChat]
    var worktrees: [ProjWorktree]
    var days: Int { daySet.count }
    var sortName: String { displayName }
    var displayName: String {
        machineName.isEmpty ? name : "\(name) · \(machineName)"
    }
    var nestedCount: Int {
        chats.count + worktrees.count + worktrees.reduce(0) { $0 + $1.chats.count }
    }
    var expandable: Bool { !chats.isEmpty || !worktrees.isEmpty }
}

struct ProjTreeRow: Identifiable, ProjSortable {
    let id: String
    let name: String
    let repositoryURL: String
    let tokens: Double
    let cost: Double
    var share = 0.0
    let days: Int
    let dur: Double
    let lastActive: String
    var folders: [ProjFolder]
    var sortName: String { name }
    var chats: [ProjChat] { folders.flatMap(\.chats) }
    var worktrees: [ProjWorktree] { folders.flatMap(\.worktrees) }
    var nestedCount: Int {
        folders.count + folders.reduce(0) { $0 + $1.nestedCount }
    }
    var expandable: Bool { !folders.isEmpty }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        func hit(_ value: String) -> Bool { value.localizedCaseInsensitiveContains(q) }
        return hit(name) || hit(id) || hit(repositoryURL)
            || folders.contains { folder in
                hit(folder.name) || hit(folder.path) || hit(folder.machineName)
                    || hit(folder.machineID)
                    || folder.chats.contains { hit($0.id) || hit($0.title) }
                    || folder.worktrees.contains {
                        hit($0.name) || $0.chats.contains { hit($0.id) || hit($0.title) }
                    }
            }
    }
}

struct KPI: Identifiable {
    var id: String { label }
    let label: String
    let value: String
    let sub: String
    var hot = false
    var sensitiveValue = false
    var sensitiveSub = false
    var usageValue = false
    var usageSub = false
}

struct NamedValue: Identifiable {
    let id: String
    let name: String
    let value: Double
}

struct HeatDay {
    var date: Date
    var tokens = 0.0
    var cost = 0.0
    var input = 0.0
    var output = 0.0
    var cacheCreate = 0.0
    var cacheRead = 0.0
    var models: [NamedValue] = []
    var sources: [NamedValue] = []
    var projects: [NamedValue] = []
    var chatCount = 0
    var projCount = 0
    var peakHour: Int?
    var peakTokens = 0.0
}

struct CycleOption: Identifiable, Equatable {
    let id: String
    let label: String
}

enum TableColumn: String, CaseIterable {
    case model, cost, share, tokens, input, output, cacheRead, days
}

struct MetaLine {
    var updated = ""
    var totalCost = ""
    var totalTokens = ""
    var activeDays = 0
    var modelCount = 0
    var sourceLabels = ""
    var windowFrom = ""
    var windowTo = ""
    var schema = 0
    var sessions = 0
}

@MainActor
@Observable
final class DashboardModel {
    static let shared = DashboardModel()
    static let unattributedCostModel = "unattributed-cost"

    var range: DashRange = .cycle(nil) { didSet { persist(); recompute() } }
    var selectedSources: Set<String> = [] { didSet { persist(); recompute() } }
    var selectedModels: Set<String> = [] { didSet { persist(); recompute() } }
    var selectedPaths: Set<String> = [] { didSet { persist(); recompute() } }
    var billingDay = 26 { didSet { persist(); rebuildCycles(); recompute() } }
    var sortColumn: TableColumn = .cost { didSet { persist(); resortTotals() } }
    var sortAscending = false { didSet { persist(); resortTotals() } }
    var heatMetric: DashMetric = .tokens { didSet { persist() } }
    var projSortKey: ProjSortKey = .cost { didSet { persist(); resortProjectTree() } }
    var projSortAscending = false { didSet { persist(); resortProjectTree() } }
    var projListOpen = false
    var projExpanded: Set<String> = []
    var projQuery = ""

    private var loading = false
    private var restored = false
    private var knownSources: Set<String> = []
    private var knownModels: Set<String> = []

    private(set) var loaded = false
    private(set) var loadAttempted = false
    private(set) var series: [DayDatum] = []
    private(set) var kpis: [KPI] = []
    private(set) var modelTotals: [ModelTotal] = []
    private(set) var dow: [DOWDatum] = []
    private(set) var hourlyAll: [HourDatum] = []
    private(set) var hourlyUnattributedTokens = 0.0
    private(set) var hourlyUnattributedCost = 0.0
    private(set) var pathUnattributedTokens = 0.0
    private(set) var pathUnattributedCost = 0.0
    private(set) var modelUnfilterableCost = 0.0
    private(set) var projects: [ProjectAgg] = []
    private(set) var projectTree: [ProjTreeRow] = []
    private(set) var meta = MetaLine()
    private(set) var calendarDays: [DayPoint] = []
    private(set) var heatDetail: [String: HeatDay] = [:]
    private(set) var chartData = DashChartData()
    private(set) var revision = 0

    private(set) var allModels: [String] = []
    private(set) var allProjectPaths: [ProjectPath] = []
    private(set) var allSources: [SourceInfo] = []
    private(set) var machineGroups: [MachineGroup] = []
    private(set) var machineCollectionDates: [String: Date] = [:]
    private(set) var defaultSources: [String] = []
    private(set) var defaultModels: [String] = []
    private(set) var cycleOptions: [CycleOption] = []
    private(set) var monthOptions: [String] = []
    private var modelIndex: [String: Int] = [:]
    private var sourceIndex: [String: Int] = [:]

    private var data: DashUsage?
    private var sortedPeriods: [String] = []
    private var mtime: Date?
    private var dataDirWatch: DispatchSourceFileSystemObject?
    private var reloadDebounce: Task<Void, Never>?

    private let cal = Calendar.current
    private let preferences: UserDefaults

    init(preferences: UserDefaults = SharedDefaults.store) {
        self.preferences = preferences
        syncExtensionState()
    }

    private func watchDataDir() {
        guard extensionEnabled, dataDirWatch == nil else { return }
        let fd = open(Repo.dataDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        dataDirWatch = source
    }

    func syncExtensionState() {
        if extensionEnabled {
            watchDataDir()
        } else {
            reloadDebounce?.cancel()
            reloadDebounce = nil
            dataDirWatch?.cancel()
            dataDirWatch = nil
        }
    }

    private var extensionEnabled: Bool {
        preferences.object(forKey: AppStorageKeys.Tabs.usageEnabled) as? Bool ?? false
    }

    private func scheduleReload() {
        guard extensionEnabled else { return }
        reloadDebounce?.cancel()
        reloadDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    static let ymd: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func modelColor(_ model: String, dark: Bool) -> Color {
        DashPalette.modelColor(modelIndex[model], dark: dark)
    }
    func modelLabel(_ model: String) -> String {
        model == Self.unattributedCostModel ? "Unattributed cost" : DashFmt.shortModel(model)
    }
    func sourceColor(_ source: String, dark: Bool) -> Color {
        DashPalette.sourceColor(sourceIndex[source], dark: dark)
    }
    func sourceLabel(_ id: String) -> String {
        allSources.first { $0.id == id }?.label ?? id
    }

    func load() async {
        syncExtensionState()
        guard extensionEnabled else { return }
        let url = Repo.usageJSON
        defer { loadAttempted = true }
        for attempt in 0..<4 {
            let m =
                (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate])
                as? Date
            if let m, m == mtime, data != nil { return }
            if let parsed = try? await Task.detached(
                priority: .utility,
                operation: {
                    try JSONDecoder().decode(DashUsage.self, from: Data(contentsOf: url))
                }
            ).value {
                mtime = m
                ingest(parsed)
                return
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    func ingest(_ parsed: DashUsage) {
        data = parsed
        sortedPeriods = parsed.daily.map(\.period).sorted()
        let srcIds = (parsed.sources ?? []).filter { id in
            parsed.daily.contains { ($0.bySource?[id]?.isEmpty == false) }
        }
        let ids = srcIds.isEmpty ? (parsed.sources ?? ["cli"]) : srcIds
        allSources = ids.map { SourceInfo(id: $0, label: parsed.sourceMeta?[$0]?.label ?? $0) }
        sourceIndex = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        machineGroups = Self.groupByMachine(
            ids, meta: parsed.sourceMeta ?? [:], naming: Self.registryNames())
        machineCollectionDates = Dictionary(
            parsed.machines?.compactMap { machine in
                guard let rawID = machine.id, let id = UUID(uuidString: rawID),
                    let collectedAt = EdithDate.parseISO(machine.collectedAt)
                else { return nil }
                return (id.uuidString.lowercased(), collectedAt)
            } ?? [],
            uniquingKeysWith: max)
        defaultSources = (parsed.defaultSources ?? ids).filter { ids.contains($0) }
        if defaultSources.isEmpty { defaultSources = ids }

        var usageByModel: [String: (cost: Double, tokens: Double)] = [:]
        for day in parsed.daily {
            for (_, rows) in day.bySource ?? [:] {
                for row in rows where !Self.isUnattributedCost(row) {
                    let name = row.modelName ?? "unknown"
                    var usage = usageByModel[name] ?? (0, 0)
                    usage.cost += row.cost ?? 0
                    usage.tokens += row.tokens
                    usageByModel[name] = usage
                }
            }
        }
        allModels = usageByModel.sorted {
            if $0.value.cost != $1.value.cost { return $0.value.cost > $1.value.cost }
            if $0.value.tokens != $1.value.tokens { return $0.value.tokens > $1.value.tokens }
            return $0.key < $1.key
        }.map(\.key)
        modelIndex = Dictionary(uniqueKeysWithValues: allModels.enumerated().map { ($1, $0) })
        defaultModels = allModels

        var byPath: [String: (name: String, tokens: Double)] = [:]
        for day in parsed.daily {
            for p in day.projects ?? [] {
                guard let path = p.path, !path.isEmpty else { continue }
                let last = URL(fileURLWithPath: path).lastPathComponent
                let name = p.folderName ?? (last.isEmpty ? p.projectName ?? "unknown" : last)
                byPath[path, default: (name, 0)].tokens += p.tokens ?? 0
            }
        }
        allProjectPaths =
            byPath
            .map { ProjectPath(path: $0.key, name: $0.value.name, tokens: $0.value.tokens) }
            .sorted { ($0.tokens, $1.path) > ($1.tokens, $0.path) }

        rebuildCycles()
        var months = Set<String>()
        for d in parsed.daily where d.period.count >= 7 {
            months.insert(String(d.period.prefix(7)))
        }
        monthOptions = months.sorted(by: >)

        if restored {
            reconcile()
        } else {
            restore()
            restored = true
        }
        rebuildActivity(parsed)
        loaded = true
        recompute()
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
            agents[key, default: []].append(Self.agentName(entry, id: id, local: local))
        }
        let groups = order.map {
            MachineGroup(
                id: $0, name: names[$0] ?? $0, sourceIDs: sources[$0] ?? [],
                agentNames: agents[$0] ?? [])
        }
        guard groups.count > 1 else { return [] }
        return groups
    }

    func machineIsShown(_ group: MachineGroup) -> Bool {
        !group.sourceIDs.isEmpty && group.sourceIDs.allSatisfy { selectedSources.contains($0) }
    }

    func machineIsPartlyShown(_ group: MachineGroup) -> Bool {
        group.sourceIDs.contains { selectedSources.contains($0) } && !machineIsShown(group)
    }

    func machineFreshness(_ group: MachineGroup, now: Date = Date()) -> MachineUsageFreshness? {
        guard !group.isLocal, let collectedAt = machineCollectionDates[group.id] else { return nil }
        return MachineUsageFreshness(collectedAt: collectedAt, now: now)
    }

    func showMachine(_ group: MachineGroup, _ shown: Bool) {
        var next = selectedSources
        if shown {
            next.formUnion(group.sourceIDs)
        } else {
            next.subtract(group.sourceIDs)
        }
        guard !next.isEmpty else { return }
        selectedSources = next
    }

    func showOnlyMachine(_ group: MachineGroup) {
        guard !group.sourceIDs.isEmpty else { return }
        selectedSources = Set(group.sourceIDs)
    }

    private func restore() {
        loading = true
        defer { loading = false }
        let d = preferences
        if let rs = d.string(forKey: "dashRange") { range = decodeRange(rs) }
        let validSources = Set(allSources.map(\.id))
        let savedSources = d.string(forKey: "dashSources").flatMap(Self.decodeSet)
        let savedKnownSources = d.string(forKey: "dashKnownSources").flatMap(Self.decodeSet)
        let savedSourceVersion = (d.object(forKey: "dashSourceSelectionVersion") as? NSNumber)?
            .intValue
        selectedSources = UsageSourceSelection.restore(
            selected: savedSources, known: savedKnownSources, storedVersion: savedSourceVersion,
            available: validSources, defaults: Set(defaultSources))
        let validModels = Set(allModels)
        if let raw = d.string(forKey: "dashModels"), !raw.isEmpty {
            let saved = Set(raw.split(separator: ",").map(String.init)).intersection(validModels)
            selectedModels = saved.isEmpty ? Set(defaultModels) : saved
        } else if selectedModels.isEmpty || selectedModels.isDisjoint(with: validModels) {
            selectedModels = Set(defaultModels)
        }
        if let raw = d.string(forKey: "dashPaths"), !raw.isEmpty {
            selectedPaths = reconciledPaths(Set(raw.split(separator: "\n").map(String.init)))
        }
        if d.object(forKey: "dashBillingDay") != nil {
            billingDay = min(max(d.integer(forKey: "dashBillingDay"), 1), 31)
        }
        if let sc = d.string(forKey: "dashSort"), let col = TableColumn(rawValue: sc) {
            sortColumn = col
        }
        sortAscending = d.bool(forKey: "dashSortAsc")
        if let ps = d.string(forKey: "projSort"), let key = ProjSortKey(rawValue: ps) {
            projSortKey = key
        }
        projSortAscending = d.bool(forKey: "projSortAsc")
        if let hm = d.string(forKey: "dashHeatMetric"), let m = DashMetric(rawValue: hm) {
            heatMetric = m
        }
        knownSources = validSources
        knownModels = validModels
        d.set(selectedSources.sorted().joined(separator: ","), forKey: "dashSources")
        d.set(knownSources.sorted().joined(separator: ","), forKey: "dashKnownSources")
        d.set(UsageSourceSelection.currentVersion, forKey: "dashSourceSelectionVersion")
    }

    private func reconcile() {
        loading = true
        defer { loading = false }
        let validSources = Set(allSources.map(\.id))
        let keptSources =
            UsageSourceSelection.reconcile(
                selected: selectedSources, known: knownSources, available: validSources,
                defaults: Set(defaultSources))
        selectedSources = keptSources
        knownSources = validSources
        preferences.set(
            knownSources.sorted().joined(separator: ","), forKey: "dashKnownSources")
        let validModels = Set(allModels)
        let keptModels =
            selectedModels.union(validModels.subtracting(knownModels)).intersection(validModels)
        selectedModels = keptModels.isEmpty ? Set(defaultModels) : keptModels
        knownModels = validModels
        selectedPaths = reconciledPaths(selectedPaths)
        preferences.set(selectedModels.sorted().joined(separator: ","), forKey: "dashModels")
        preferences.set(selectedPaths.sorted().joined(separator: "\n"), forKey: "dashPaths")
    }

    private func reconciledPaths(_ paths: Set<String>) -> Set<String> {
        paths.filter { scope in
            allProjectPaths.contains { entry in
                Self.path(entry.path, isWithin: scope) || Self.path(scope, isWithin: entry.path)
            }
        }
    }

    private static func path(_ path: String, isWithin scope: String) -> Bool {
        let caseSensitive = !path.hasPrefix("/") || !scope.hasPrefix("/")
        let value = normalizedPath(path, caseSensitive: caseSensitive)
        let parent = normalizedPath(scope, caseSensitive: caseSensitive)
        guard !value.isEmpty, !parent.isEmpty else { return false }
        return value == parent || value.hasPrefix(parent + "/")
    }

    private static func normalizedPath(_ path: String, caseSensitive: Bool) -> String {
        let raw = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = caseSensitive ? raw : raw.lowercased()
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    private func persist() {
        guard !loading else { return }
        let d = preferences
        d.set(encodeRange(range), forKey: "dashRange")
        d.set(selectedSources.sorted().joined(separator: ","), forKey: "dashSources")
        d.set(knownSources.sorted().joined(separator: ","), forKey: "dashKnownSources")
        d.set(UsageSourceSelection.currentVersion, forKey: "dashSourceSelectionVersion")
        d.set(selectedModels.sorted().joined(separator: ","), forKey: "dashModels")
        d.set(selectedPaths.sorted().joined(separator: "\n"), forKey: "dashPaths")
        d.set(billingDay, forKey: "dashBillingDay")
        d.set(sortColumn.rawValue, forKey: "dashSort")
        d.set(sortAscending, forKey: "dashSortAsc")
        d.set(projSortKey.rawValue, forKey: "projSort")
        d.set(projSortAscending, forKey: "projSortAsc")
        d.set(heatMetric.rawValue, forKey: "dashHeatMetric")
    }

    private func encodeRange(_ r: DashRange) -> String {
        switch r {
        case .today: return "today"
        case .yesterday: return "yesterday"
        case .thisWeek: return "thisWeek"
        case .lastWeek: return "lastWeek"
        case .all: return "all"
        case .cycle(let id): return id.map { "cycle:\($0)" } ?? "cycle"
        case .month(let ym): return "month:\(ym)"
        case .custom(let f, let t): return "custom:\(f)~\(t)"
        }
    }

    private static func decodeSet(_ raw: String) -> Set<String>? {
        let values = Set(raw.split(separator: ",").map(String.init))
        return values.isEmpty ? nil : values
    }

    private func decodeRange(_ s: String) -> DashRange {
        switch s {
        case "today": return .today
        case "yesterday": return .yesterday
        case "thisWeek": return .thisWeek
        case "lastWeek": return .lastWeek
        case "all": return .all
        case "cycle": return .cycle(nil)
        default:
            if s.hasPrefix("cycle:") { return .cycle(String(s.dropFirst(6))) }
            if s.hasPrefix("month:") { return .month(String(s.dropFirst(6))) }
            if s.hasPrefix("custom:") {
                let parts = s.dropFirst(7).split(separator: "~", maxSplits: 1).map(String.init)
                if parts.count == 2 { return .custom(parts[0], parts[1]) }
            }
            return .cycle(nil)
        }
    }

    func reset() {
        range = .cycle(nil)
        selectedSources = Set(defaultSources)
        selectedModels = Set(defaultModels)
        selectedPaths = []
        sortColumn = .cost
        sortAscending = false
        projSortKey = .cost
        projSortAscending = false
        heatMetric = .tokens
        projExpanded = []
        projListOpen = false
        projQuery = ""
    }

    private func parseYMD(_ s: String) -> Date? { Self.ymd.date(from: s) }
    private func ymdStr(_ d: Date) -> String { Self.ymd.string(from: d) }

    private static func isUnattributedCost(_ row: DashUsage.Model) -> Bool {
        let name = row.modelName ?? "unknown"
        return name == unattributedCostModel
            || (row.tokens == 0 && (row.cost ?? 0) > 0)
    }

    var tokenBearingModelTotals: [ModelTotal] {
        modelTotals.filter { $0.model != Self.unattributedCostModel && $0.tokens > 0 }
    }

    var dataRange: ClosedRange<Date>? {
        guard let first = sortedPeriods.first, let last = sortedPeriods.last,
            let e = parseYMD(first), let l = parseYMD(last)
        else { return nil }
        return e...max(l, cal.startOfDay(for: Date()))
    }

    func ymd(_ d: Date) -> String { ymdStr(d) }

    private func rebuildCycles() {
        guard data != nil else { return }
        let periods = sortedPeriods
        guard let first = periods.first, let last = periods.last,
            let earliest = parseYMD(first), let latest = parseYMD(last)
        else {
            cycleOptions = []
            return
        }
        var out: [CycleOption] = []
        var start = cycleStart(earliest)
        while start <= latest {
            let end = cycleEnd(start)
            out.append(CycleOption(id: ymdStr(start), label: cycleLabel(start, end)))
            start = cal.date(byAdding: .day, value: 1, to: end) ?? latest
            if start > latest { break }
            start = cycleStart(start)
        }
        cycleOptions = out.reversed()
    }

    private func daysInMonth(_ date: Date) -> Int {
        cal.range(of: .day, in: .month, for: date)?.count ?? 30
    }

    private func anchor(_ date: Date, _ day: Int) -> Date {
        var comps = cal.dateComponents([.year, .month], from: date)
        comps.day = min(day, daysInMonth(date))
        return cal.date(from: comps) ?? date
    }

    private func cycleStart(_ date: Date) -> Date {
        let d = cal.component(.day, from: date)
        let a = min(billingDay, daysInMonth(date))
        if d >= a { return anchor(date, billingDay) }
        let prev = cal.date(byAdding: .month, value: -1, to: date) ?? date
        return anchor(prev, billingDay)
    }

    private func cycleEnd(_ start: Date) -> Date {
        let next = cal.date(byAdding: .month, value: 1, to: start) ?? start
        let a = anchor(next, billingDay)
        return cal.date(byAdding: .day, value: -1, to: a) ?? start
    }

    private static let dayMonthFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM"
        return f
    }()
    private static let yearFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy"
        return f
    }()

    private func cycleLabel(_ start: Date, _ end: Date) -> String {
        let f = Self.dayMonthFmt
        let yf = Self.yearFmt
        let sameYear = yf.string(from: start) == yf.string(from: end)
        let left =
            sameYear ? f.string(from: start) : "\(f.string(from: start)) \(yf.string(from: start))"
        return "\(left) – \(f.string(from: end)) \(yf.string(from: end))"
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
        case .cycle(let start):
            let s = start.flatMap(parseYMD) ?? cycleStart(today)
            return (s, min(cycleEnd(s), today))
        case .month(let ym):
            guard let d = DateFormatter.monthParser.date(from: ym) else {
                return (earliest, latest)
            }
            let start = cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
            let end = anchor(cal.date(byAdding: .month, value: 1, to: start) ?? start, 1)
            return (start, cal.date(byAdding: .day, value: -1, to: end) ?? start)
        case .custom(let f, let t):
            guard let fd = parseYMD(f), let td = parseYMD(t) else { return (earliest, latest) }
            return (min(fd, td), max(fd, td))
        }
    }

    private func resortTotals() {
        modelTotals.sort(by: sortComparator)
    }

    private func recompute() {
        guard loaded, let data, let win = window() else { return }
        revision &+= 1
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
        let fullModelScope = selectedModels == Set(allModels)

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
                            guard !Self.isUnattributedCost(row), row.tokens > 0 else { return nil }
                            return row.modelName ?? "unknown"
                        })
                    let selectedSourceModels = sourceTokenModels.intersection(selectedModels)
                    let includeUnattributedCost =
                        fullModelScope
                        || (!sourceTokenModels.isEmpty
                            && sourceTokenModels.isSubset(of: selectedModels))
                    for m in models {
                        let unattributedCost = Self.isUnattributedCost(m)
                        if unattributedCost, !includeUnattributedCost {
                            if !selectedSourceModels.isEmpty {
                                unfilterableModelCost += m.cost ?? 0
                            }
                            continue
                        }
                        let name =
                            unattributedCost
                            ? Self.unattributedCostModel : (m.modelName ?? "unknown")
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
                    let repository = repositoryIdentity(p)
                    let folder = folderIdentity(p, repository: repository)
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
        series = rows

        let totalCost = modelAgg.values.reduce(0) { $0 + $1.cost }
        let totalModelTokens = modelAgg.values.reduce(0) { $0 + $1.tokens }
        var totals = modelAgg.map { name, a in
            ModelTotal(
                id: name, model: name, tokens: a.tokens, cost: a.cost, input: a.input,
                output: a.output, cacheRead: a.cacheRead, days: a.days.count,
                share: totalCost > 0 ? a.cost / totalCost : 0,
                tokenShare: totalModelTokens > 0 ? a.tokens / totalModelTokens : 0)
        }
        totals.sort(by: sortComparator)
        modelTotals = totals

        let wdLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        dow = (0..<7).map {
            DOWDatum(label: wdLabels[$0], tokens: dowTokens[$0], cost: dowCost[$0])
        }
        hourlyAll = (0..<24).map {
            HourDatum(id: $0, hour: $0, tokens: hourTok[$0], cost: hourCost[$0])
        }
        hourlyUnattributedTokens = hourlyUnattributed.tokens
        hourlyUnattributedCost = hourlyUnattributed.cost
        pathUnattributedTokens = pathUnattributed.tokens
        pathUnattributedCost = pathUnattributed.cost
        modelUnfilterableCost = unfilterableModelCost

        let totalTokens = rows.reduce(0) { $0 + $1.tokens }
        let activeDays = Set(rows.filter { $0.tokens > 0 || $0.cost > 0 }.map(\.id))
        projectTree = buildProjectTree(
            projAgg, targetTokens: totalTokens, targetCost: totalCost, targetDays: activeDays)
        projects = projectTree.map {
            ProjectAgg(id: $0.id, name: $0.name, tokens: $0.tokens, cost: $0.cost, share: $0.share)
        }
        .sorted { $0.tokens > $1.tokens }

        buildKPIs(rows: rows, totalCost: totalCost)
        buildMeta(from: fromStr, to: toStr)
        rebuildChartData()
    }

    private func chatVisible(_ source: String?) -> Bool {
        guard let source, !source.isEmpty else { return true }
        return selectedSources.contains(source)
    }

    func pathInScope(_ path: String?) -> Bool {
        guard !selectedPaths.isEmpty else { return true }
        guard let path, !path.isEmpty else { return false }
        return selectedPaths.contains { Self.path(path, isWithin: $0) }
    }

    private func chatInScope(_ c: DashUsage.Chat, fallback: String?) -> Bool {
        chatVisible(c.source) && pathInScope(c.path ?? fallback)
    }

    private func knownPath(_ p: DashUsage.Project) -> String? {
        p.path
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

    private struct ProjectAttributionKey: Hashable {
        let source: String
        let model: String
    }

    private struct UsageAmount {
        var tokens = 0.0
        var cost = 0.0
    }

    private struct ProjectAllocation {
        let project: DashUsage.Project
        var amount = UsageAmount()
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
                let amount = sourceAmount(
                    breakdown, model: key.model, useSourceTotal: useSourceTotal)
            else { return UsageAmount() }
            let scope = projectScope(
                project, source: key.source, allowChatScope: useSourceTotal, scoped: scoped)
            return UsageAmount(
                tokens: amount.tokens * scope.tokens,
                cost: amount.cost * scope.cost)
        }
        if let bySource = project.bySource, !bySource.isEmpty { return UsageAmount() }

        let hasFullModelScope = selectedModels == Set(allModels)
        guard hasFullModelScope || useSourceTotal else { return UsageAmount() }
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
                guard !Self.isUnattributedCost(row), row.tokens > 0 else { return nil }
                return row.modelName ?? "unknown"
            })
        return key.model == Self.unattributedCostModel
            || (tokenModels.count == 1 && tokenModels.contains(key.model))
    }

    private func sourceAmount(
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

    private struct HourlyAllocation {
        var tokens = [Double](repeating: 0, count: 24)
        var cost = [Double](repeating: 0, count: 24)
        var unattributed = UsageAmount()
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
                            let amount = sourceAmount(
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
                        let amount = sourceAmount(
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

    private func rebuildActivity(_ parsed: DashUsage) {
        var detail: [String: HeatDay] = [:]
        var dates: [Date] = []
        for day in parsed.daily {
            guard let date = parseYMD(day.period) else { continue }
            dates.append(date)
            detail[day.period] = activityHeatDay(day, date: date)
        }
        guard let first = dates.min(), let last = dates.max() else {
            heatDetail = [:]
            calendarDays = []
            return
        }
        buildCalendar(detail: detail, from: first, to: last)
    }

    private func activityHeatDay(_ day: DashUsage.Day, date: Date) -> HeatDay {
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
            NamedValue(id: $0.key, name: sourceLabel($0.key), value: $0.value)
        }
        activityProjects(day, heat: &heat)
        activityPeak(day, heat: &heat)
        return heat
    }

    private func activityProjects(_ day: DashUsage.Day, heat: inout HeatDay) {
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

    private func activityPeak(_ day: DashUsage.Day, heat: inout HeatDay) {
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

    private func projectScale(
        _ project: DashUsage.Project, targetTokens: Double, targetCost: Double
    ) -> DayScale {
        let raw = rawUsage(project, scoped: true)
        return DayScale(
            rawTokens: raw.tokens, rawCost: raw.cost, dayTokens: targetTokens,
            dayCost: targetCost)
    }

    private func rebuildChartData() {
        var next = DashChartData()
        next.daily = series.map {
            ComboPoint(id: $0.id, label: $0.label, tokens: $0.tokens, cost: $0.cost)
        }
        next.dow = dow.map {
            ComboPoint(id: $0.label, label: $0.label, tokens: $0.tokens, cost: $0.cost)
        }
        next.hourly = hourlyAll.map {
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
        next.tokenMix = series.flatMap { d in
            [
                StackDatum(id: "\(d.id)-in", x: d.label, series: "input", value: d.input),
                StackDatum(id: "\(d.id)-out", x: d.label, series: "output", value: d.output),
                StackDatum(
                    id: "\(d.id)-cc", x: d.label, series: "cache write", value: d.cacheCreate),
                StackDatum(id: "\(d.id)-cr", x: d.label, series: "cache read", value: d.cacheRead),
            ]
        }
        next.modelTime = series.flatMap { d in
            d.byModel.map {
                StackDatum(
                    id: "\(d.id)-\($0.key)", x: d.label, series: DashFmt.shortModel($0.key),
                    value: $0.value)
            }
        }
        next.source = series.flatMap { d in
            d.bySource.map {
                StackDatum(
                    id: "\(d.id)-\($0.key)", x: d.label, series: sourceLabel($0.key),
                    value: $0.value)
            }
        }
        let costs = calendarDays.map(\.cost).filter { $0 > 0 }.sorted()
        next.heatCuts =
            costs.isEmpty
            ? [0, 0, 0]
            : [costs[costs.count / 4], costs[costs.count / 2], costs[costs.count * 3 / 4]]
        chartData = next
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

    private func repositoryIdentity(_ project: DashUsage.Project) -> RepositoryIdentity {
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

    private func folderIdentity(
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

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizeRepositoryURL(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalized.hasSuffix("/") { normalized.removeLast() }
        if normalized.hasSuffix(".git") { normalized.removeLast(4) }
        return normalized
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
        return sortTree(rows)
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

    func projLess(_ a: some ProjSortable, _ b: some ProjSortable) -> Bool {
        let asc = projSortAscending
        func cmp<T: Comparable>(_ x: T, _ y: T) -> Bool { asc ? x < y : x > y }
        switch projSortKey {
        case .name: return cmp(a.sortName, b.sortName)
        case .tokens: return cmp(a.tokens, b.tokens)
        case .cost: return cmp(a.cost, b.cost)
        case .share: return cmp(a.share, b.share)
        case .days: return cmp(a.days, b.days)
        case .dur: return cmp(a.dur, b.dur)
        case .lastActive: return cmp(a.lastActive, b.lastActive)
        }
    }

    private func resortProjectTree() {
        guard !loading, !projectTree.isEmpty else { return }
        projectTree = sortTree(projectTree)
    }

    private func sortTree(_ rows: [ProjTreeRow]) -> [ProjTreeRow] {
        rows.map { row in
            var r = row
            r.folders = row.folders.map { folder in
                var f = folder
                f.chats = folder.chats.sorted(by: projLess)
                f.worktrees = folder.worktrees.map { worktree in
                    var w = worktree
                    w.chats = worktree.chats.sorted(by: projLess)
                    return w
                }
                .sorted(by: projLess)
                return f
            }
            .sorted(by: projLess)
            return r
        }
        .sorted(by: projLess)
    }

    private func sortComparator(_ a: ModelTotal, _ b: ModelTotal) -> Bool {
        let asc = sortAscending
        func cmp<T: Comparable>(_ x: T, _ y: T) -> Bool { asc ? x < y : x > y }
        switch sortColumn {
        case .model: return asc ? a.model < b.model : a.model > b.model
        case .cost: return cmp(a.cost, b.cost)
        case .share: return cmp(a.share, b.share)
        case .tokens: return cmp(a.tokens, b.tokens)
        case .input: return cmp(a.input, b.input)
        case .output: return cmp(a.output, b.output)
        case .cacheRead: return cmp(a.cacheRead, b.cacheRead)
        case .days: return cmp(a.days, b.days)
        }
    }

    private func buildKPIs(rows: [DayDatum], totalCost: Double) {
        let totalTokens = rows.reduce(0) { $0 + $1.tokens }
        let active = rows.filter { $0.tokens > 0 }
        let busiest = rows.max { $0.tokens < $1.tokens }
        let cacheRead = rows.reduce(0) { $0 + $1.cacheRead }
        let input = rows.reduce(0) { $0 + $1.input }
        let output = rows.reduce(0) { $0 + $1.output }
        let cacheCreate = rows.reduce(0) { $0 + $1.cacheCreate }
        let cacheRate = (cacheRead + input) > 0 ? cacheRead / (cacheRead + input) : 0
        let top = tokenBearingModelTotals.max { $0.tokens < $1.tokens }

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
                    label: "Top model", value: modelLabel(top.model),
                    sub: "\(DashFmt.tokens(top.tokens)) · \(DashFmt.pct(top.tokenShare)) of tokens",
                    usageSub: true))
        }
        kpis = out
    }

    private func buildMeta(from: String, to: String) {
        guard let data else { return }
        var m = MetaLine()
        if let gen = data.generatedAt, let d = EdithDate.parseISO(gen) {
            m.updated = d.formatted(date: .abbreviated, time: .shortened)
        }
        m.totalCost = DashFmt.usd(series.reduce(0) { $0 + $1.cost })
        m.totalTokens = DashFmt.tokens(series.reduce(0) { $0 + $1.tokens })
        m.activeDays = series.filter { $0.tokens > 0 }.count
        m.modelCount = modelTotals.filter { $0.tokens > 0 }.count
        m.sourceLabels = allSources.filter { selectedSources.contains($0.id) }.map(\.label).joined(
            separator: " + ")
        m.windowFrom = String(from.dropFirst(5))
        m.windowTo = String(to.dropFirst(5))
        m.schema = data.schemaVersion ?? 0
        m.sessions = data.sessions?.count ?? 0
        meta = m
    }

    private func buildCalendar(detail: [String: HeatDay], from: Date, to: Date) {
        heatDetail = detail
        let first = cal.startOfDay(for: min(from, to))
        let last = cal.startOfDay(for: max(from, to))
        let firstWeekday = (cal.component(.weekday, from: first) + 5) % 7
        let lastWeekday = (cal.component(.weekday, from: last) + 5) % 7
        var day = cal.date(byAdding: .day, value: -firstWeekday, to: first) ?? first
        let end = cal.date(byAdding: .day, value: 6 - lastWeekday, to: last) ?? last
        var points: [DayPoint] = []
        while day <= end {
            let key = ymdStr(day)
            points.append(DayPoint(id: key, date: day, cost: detail[key]?.cost ?? 0))
            day = cal.date(byAdding: .day, value: 1, to: day) ?? end.addingTimeInterval(1)
        }
        calendarDays = points
    }
}

extension DateFormatter {
    static let monthParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f
    }()
}

enum DashFmt {
    static func tokens(_ v: Double) -> String {
        TokenFormatter.compact(v)
    }
    private static let tokensFullFmt: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()
    private static let usdLongFmt: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()
    static func tokensFull(_ v: Double) -> String {
        tokensFullFmt.string(from: NSNumber(value: v)) ?? "\(Int(v))"
    }
    static func usd(_ v: Double) -> String {
        if v >= 1000 { return String(format: "$%.1fk", v / 1000) }
        return String(format: "$%.2f", v)
    }
    static func usdFull(_ v: Double) -> String { String(format: "$%.2f", v) }
    static func usdLong(_ v: Double) -> String {
        "$" + (usdLongFmt.string(from: NSNumber(value: v)) ?? String(format: "%.2f", v))
    }
    static func pct(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }
    static func duration(_ ms: Double) -> String {
        guard ms > 0 else { return "-" }
        let s = Int((ms / 1000).rounded())
        if s < 60 { return "\(s)s" }
        let m = Int((Double(s) / 60).rounded())
        if m < 60 { return "\(m)m" }
        let h = m / 60
        let rem = m % 60
        return rem > 0 ? "\(h)h \(rem)m" : "\(h)h"
    }
    static func dateShort(_ ymd: String) -> String {
        let parts = ymd.split(separator: "-")
        guard parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]), (1...12).contains(m)
        else { return "-" }
        let mon = [
            "Jan", "Feb", "Mar", "Apr", "May", "Jun",
            "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        ]
        return "\(mon[m - 1]) \(d)"
    }
    static func shortModel(_ m: String) -> String {
        var s = m
        if s.hasPrefix("claude-") { s.removeFirst("claude-".count) }
        if let r = s.range(of: #"-\d{8}$"#, options: .regularExpression) { s.removeSubrange(r) }
        return s
    }
}
