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
    static let unattributedCostModel = DashboardComputation.unattributedCostModel

    var range: DashRange = .all { didSet { persist(.range); recompute() } }
    var selectedSources: Set<String> = [] { didSet { persist(.sources); recompute() } }
    var selectedModels: Set<String> = [] { didSet { persist(.models); recompute() } }
    var selectedPaths: Set<String> = [] { didSet { persist(.paths); recompute() } }
    var sortColumn: TableColumn = .cost { didSet { persist(.sort); resortTotals() } }
    var sortAscending = false { didSet { persist(.sortAscending); resortTotals() } }
    var heatMetric: DashMetric = .tokens { didSet { persist(.heatMetric) } }
    var projSortKey: ProjSortKey = .cost { didSet { persist(.projSort); resortProjectTree() } }
    var projSortAscending = false { didSet { persist(.projSortAscending); resortProjectTree() } }
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
    private(set) var monthOptions: [String] = []
    private var modelIndex: [String: Int] = [:]
    private var sourceIndex: [String: Int] = [:]

    private var data: DashUsage?
    private var sortedPeriods: [String] = []
    private var mtime: Date?
    private var dataDirWatch: DispatchSourceFileSystemObject?
    private var reloadDebounce: Task<Void, Never>?
    private var ingestGeneration = 0
    private var computeGeneration = 0
    private var computeTask: Task<Void, Never>?

    private static let inlineComputeDayLimit = 32

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

    static let ymd = DashboardComputation.ymd

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
        let loadTrace = PerformanceTrace.begin(.repository, "dashboard.load")
        defer { PerformanceTrace.end(loadTrace) }
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
                await ingestDetached(parsed)
                return
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    func ingest(_ parsed: DashUsage) {
        let ingestTrace = PerformanceTrace.begin(.largeRepository, "dashboard.ingest")
        defer { PerformanceTrace.end(ingestTrace) }
        ingestGeneration &+= 1
        apply(DashboardComputation.digest(parsed, calendar: cal), parsed: parsed)
        recompute()
    }

    private func ingestDetached(_ parsed: DashUsage) async {
        let ingestTrace = PerformanceTrace.begin(.largeRepository, "dashboard.ingest")
        defer { PerformanceTrace.end(ingestTrace) }
        ingestGeneration &+= 1
        let generation = ingestGeneration
        let calendar = cal
        let digest = await Task.detached(
            priority: .userInitiated,
            operation: { DashboardComputation.digest(parsed, calendar: calendar) }
        ).value
        if generation != ingestGeneration { return }
        apply(digest, parsed: parsed)
        recompute()
        await awaitPendingComputation()
    }

    private func apply(_ digest: DashboardIngestDigest, parsed: DashUsage) {
        data = parsed
        sortedPeriods = digest.sortedPeriods
        allSources = digest.allSources
        sourceIndex = digest.sourceIndex
        machineGroups = digest.machineGroups
        machineCollectionDates = digest.machineCollectionDates
        defaultSources = digest.defaultSources
        allModels = digest.allModels
        modelIndex = digest.modelIndex
        defaultModels = digest.defaultModels
        allProjectPaths = digest.allProjectPaths
        monthOptions = digest.monthOptions
        if restored {
            reconcile()
        } else {
            restore()
            restored = true
        }
        heatDetail = digest.heatDetail
        calendarDays = digest.calendarDays
        loaded = true
    }

    func awaitPendingComputation() async {
        await computeTask?.value
    }

    static func agentName(_ entry: DashUsage.Meta?, id: String, local: Bool) -> String {
        DashboardComputation.agentName(entry, id: id, local: local)
    }

    static func groupByMachine(
        _ ids: [String], meta: [String: DashUsage.Meta], naming: [String: String]
    ) -> [MachineGroup] {
        DashboardComputation.groupByMachine(ids, meta: meta, naming: naming)
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
        if let rs = d.string(forKey: "dashRange") {
            range = decodeRange(rs)
            d.set(encodeRange(range), forKey: "dashRange")
        }
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
                DashboardComputation.path(entry.path, isWithin: scope)
                    || DashboardComputation.path(scope, isWithin: entry.path)
            }
        }
    }

    private enum PersistedSetting: CaseIterable {
        case range, sources, models, paths, sort, sortAscending
        case projSort, projSortAscending, heatMetric
    }

    private func persist(_ setting: PersistedSetting) {
        guard !loading else { return }
        let d = preferences
        switch setting {
        case .range:
            d.set(encodeRange(range), forKey: "dashRange")
        case .sources:
            d.set(selectedSources.sorted().joined(separator: ","), forKey: "dashSources")
            d.set(knownSources.sorted().joined(separator: ","), forKey: "dashKnownSources")
            d.set(UsageSourceSelection.currentVersion, forKey: "dashSourceSelectionVersion")
        case .models:
            d.set(selectedModels.sorted().joined(separator: ","), forKey: "dashModels")
        case .paths:
            d.set(selectedPaths.sorted().joined(separator: "\n"), forKey: "dashPaths")
        case .sort:
            d.set(sortColumn.rawValue, forKey: "dashSort")
        case .sortAscending:
            d.set(sortAscending, forKey: "dashSortAsc")
        case .projSort:
            d.set(projSortKey.rawValue, forKey: "projSort")
        case .projSortAscending:
            d.set(projSortAscending, forKey: "projSortAsc")
        case .heatMetric:
            d.set(heatMetric.rawValue, forKey: "dashHeatMetric")
        }
    }

    private func encodeRange(_ r: DashRange) -> String {
        switch r {
        case .today: return "today"
        case .yesterday: return "yesterday"
        case .thisWeek: return "thisWeek"
        case .lastWeek: return "lastWeek"
        case .all: return "all"
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
        default:
            if s.hasPrefix("month:") { return .month(String(s.dropFirst(6))) }
            if s.hasPrefix("custom:") {
                let parts = s.dropFirst(7).split(separator: "~", maxSplits: 1).map(String.init)
                if parts.count == 2 { return .custom(parts[0], parts[1]) }
            }
            return .all
        }
    }

    func reset() {
        loading = true
        range = .all
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
        loading = false
        for setting in PersistedSetting.allCases {
            persist(setting)
        }
        recompute()
    }

    private func parseYMD(_ s: String) -> Date? { Self.ymd.date(from: s) }
    private func ymdStr(_ d: Date) -> String { Self.ymd.string(from: d) }

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

    private func computeRequest(_ data: DashUsage) -> DashboardComputeRequest {
        DashboardComputeRequest(
            data: data, sortedPeriods: sortedPeriods, allSources: allSources,
            allModels: allModels, calendarDays: calendarDays, range: range,
            selectedSources: selectedSources, selectedModels: selectedModels,
            selectedPaths: selectedPaths, sortColumn: sortColumn, sortAscending: sortAscending,
            projSortKey: projSortKey, projSortAscending: projSortAscending, calendar: cal)
    }

    private func publish(_ snapshot: DashboardSnapshot) {
        revision &+= 1
        series = snapshot.series
        kpis = snapshot.kpis
        modelTotals = snapshot.modelTotals
        dow = snapshot.dow
        hourlyAll = snapshot.hourlyAll
        hourlyUnattributedTokens = snapshot.hourlyUnattributedTokens
        hourlyUnattributedCost = snapshot.hourlyUnattributedCost
        pathUnattributedTokens = snapshot.pathUnattributedTokens
        pathUnattributedCost = snapshot.pathUnattributedCost
        modelUnfilterableCost = snapshot.modelUnfilterableCost
        projects = snapshot.projects
        projectTree = snapshot.projectTree
        meta = snapshot.meta
        chartData = snapshot.chartData
    }

    private func resortTotals() {
        guard !loading else { return }
        modelTotals.sort {
            DashboardComputation.modelTotalLess(
                $0, $1, column: sortColumn, ascending: sortAscending)
        }
    }

    private func recompute() {
        guard loaded, !loading, let data else { return }
        computeTask?.cancel()
        computeGeneration &+= 1
        let generation = computeGeneration
        let request = computeRequest(data)
        if data.daily.count <= Self.inlineComputeDayLimit {
            if let snapshot = DashboardComputation.snapshot(request) {
                publish(snapshot)
            }
            return
        }
        computeTask = Task { [weak self] in
            let snapshot = await Task.detached(
                priority: .userInitiated,
                operation: { DashboardComputation.snapshot(request) }
            ).value
            guard let self, !Task.isCancelled else { return }
            if generation != self.computeGeneration { return }
            if let snapshot { self.publish(snapshot) }
        }
    }

    func pathInScope(_ path: String?) -> Bool {
        DashboardComputation.pathInScope(path, selectedPaths: selectedPaths)
    }

    func projLess(_ a: some ProjSortable, _ b: some ProjSortable) -> Bool {
        DashboardComputation.projSortableLess(
            a, b, key: projSortKey, ascending: projSortAscending)
    }

    private func resortProjectTree() {
        guard !loading, !projectTree.isEmpty else { return }
        projectTree = DashboardComputation.sortTree(
            projectTree, key: projSortKey, ascending: projSortAscending)
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
