import EdithKit
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
    let daily: [Day]
    let sessions: [Session]?

    struct Meta: Decodable {
        let label: String?
        let tool: String?
    }
    struct Totals: Decodable {
        let cost: Double?
        let tokens: Double?
    }
    struct Session: Decodable {
        let id: String?
        let source: String?
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
        let tokens: Double?
        let cost: Double?
        let chats: [Chat]?
        let worktrees: [Worktree]?
    }
    struct Worktree: Decodable {
        let name: String?
        let tokens: Double?
        let cost: Double?
        let chats: [Chat]?
    }
    struct Chat: Decodable {
        let id: String?
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

struct ProjTreeRow: Identifiable, ProjSortable {
    let id: String
    let name: String
    let tokens: Double
    let cost: Double
    var share = 0.0
    let days: Int
    let dur: Double
    let lastActive: String
    var chats: [ProjChat]
    var worktrees: [ProjWorktree]
    var sortName: String { name }
    var nestedCount: Int {
        chats.count + worktrees.count + worktrees.reduce(0) { $0 + $1.chats.count }
    }
    var expandable: Bool { !chats.isEmpty || !worktrees.isEmpty }
}

struct KPI: Identifiable {
    let id = UUID()
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
final class DashboardModel: ObservableObject {
    static let shared = DashboardModel()

    @Published var range: DashRange = .cycle(nil) { didSet { persist(); recompute() } }
    @Published var selectedSources: Set<String> = [] { didSet { persist(); recompute() } }
    @Published var selectedModels: Set<String> = [] { didSet { persist(); recompute() } }
    @Published var billingDay = 26 { didSet { persist(); rebuildCycles(); recompute() } }
    @Published var sortColumn: TableColumn = .cost { didSet { persist(); resortTotals() } }
    @Published var sortAscending = false { didSet { persist(); resortTotals() } }
    @Published var heatMetric: DashMetric = .tokens { didSet { persist() } }
    @Published var projSortKey: ProjSortKey = .cost { didSet { persist(); resortProjectTree() } }
    @Published var projSortAscending = false { didSet { persist(); resortProjectTree() } }
    @Published var projListOpen = false
    @Published var projExpanded: Set<String> = []

    private var loading = false
    private var restored = false
    private var knownSources: Set<String> = []
    private var knownModels: Set<String> = []

    @Published private(set) var loaded = false
    @Published private(set) var loadAttempted = false
    @Published private(set) var series: [DayDatum] = []
    @Published private(set) var kpis: [KPI] = []
    @Published private(set) var modelTotals: [ModelTotal] = []
    @Published private(set) var dow: [DOWDatum] = []
    @Published private(set) var hourlyAll: [HourDatum] = []
    @Published private(set) var projects: [ProjectAgg] = []
    @Published private(set) var projectTree: [ProjTreeRow] = []
    @Published private(set) var meta = MetaLine()
    @Published private(set) var calendarDays: [DayPoint] = []
    @Published private(set) var heatDetail: [String: HeatDay] = [:]
    @Published private(set) var chartData = DashChartData()

    private(set) var allModels: [String] = []
    private(set) var allSources: [SourceInfo] = []
    private(set) var defaultSources: [String] = []
    private(set) var defaultModels: [String] = []
    private(set) var cycleOptions: [CycleOption] = []
    private(set) var monthOptions: [String] = []
    private var modelIndex: [String: Int] = [:]
    private var sourceIndex: [String: Int] = [:]

    private var data: DashUsage?
    private var sortedPeriods: [String] = []
    private var ingestStamp = 0
    private var calendarKey = ""
    private var mtime: Date?
    private var dataDirWatch: DispatchSourceFileSystemObject?
    private var reloadDebounce: Task<Void, Never>?

    private let cal = Calendar.current

    init() {
        watchDataDir()
    }

    private func watchDataDir() {
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

    private func scheduleReload() {
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
    func sourceColor(_ source: String, dark: Bool) -> Color {
        DashPalette.sourceColor(sourceIndex[source], dark: dark)
    }
    func sourceLabel(_ id: String) -> String {
        allSources.first { $0.id == id }?.label ?? id
    }

    func load() async {
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
        ingestStamp += 1
        let srcIds = (parsed.sources ?? []).filter { id in
            parsed.daily.contains { ($0.bySource?[id]?.isEmpty == false) }
        }
        let ids = srcIds.isEmpty ? (parsed.sources ?? ["cli"]) : srcIds
        allSources = ids.map { SourceInfo(id: $0, label: parsed.sourceMeta?[$0]?.label ?? $0) }
        sourceIndex = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        defaultSources = (parsed.defaultSources ?? ids).filter { ids.contains($0) }
        if defaultSources.isEmpty { defaultSources = ids }

        var costByModel: [String: Double] = [:]
        for day in parsed.daily {
            for (_, rows) in day.bySource ?? [:] {
                for r in rows where r.modelName != nil {
                    costByModel[r.modelName!, default: 0] += r.cost ?? 0
                }
            }
        }
        allModels = costByModel.sorted { $0.value > $1.value }.map(\.key)
        modelIndex = Dictionary(uniqueKeysWithValues: allModels.enumerated().map { ($1, $0) })
        defaultModels = allModels

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
        loaded = true
        recompute()
    }

    private func restore() {
        loading = true
        defer { loading = false }
        let d = SharedDefaults.store
        if let rs = d.string(forKey: "dashRange") { range = decodeRange(rs) }
        let validSources = Set(allSources.map(\.id))
        let savedSources = d.string(forKey: "dashSources").flatMap(Self.decodeSet)
        let savedKnownSources = d.string(forKey: "dashKnownSources").flatMap(Self.decodeSet)
        selectedSources = UsageSourceSelection.reconcile(
            selected: savedSources, known: savedKnownSources, available: validSources,
            defaults: Set(defaultSources))
        let validModels = Set(allModels)
        if let raw = d.string(forKey: "dashModels"), !raw.isEmpty {
            let saved = Set(raw.split(separator: ",").map(String.init)).intersection(validModels)
            selectedModels = saved.isEmpty ? Set(defaultModels) : saved
        } else if selectedModels.isEmpty || selectedModels.isDisjoint(with: validModels) {
            selectedModels = Set(defaultModels)
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
        d.set(knownSources.sorted().joined(separator: ","), forKey: "dashKnownSources")
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
        SharedDefaults.store.set(
            knownSources.sorted().joined(separator: ","), forKey: "dashKnownSources")
        let validModels = Set(allModels)
        let keptModels =
            selectedModels.union(validModels.subtracting(knownModels)).intersection(validModels)
        selectedModels = keptModels.isEmpty ? Set(defaultModels) : keptModels
        knownModels = validModels
    }

    private func persist() {
        guard !loading else { return }
        let d = SharedDefaults.store
        d.set(encodeRange(range), forKey: "dashRange")
        d.set(selectedSources.sorted().joined(separator: ","), forKey: "dashSources")
        d.set(knownSources.sorted().joined(separator: ","), forKey: "dashKnownSources")
        d.set(selectedModels.sorted().joined(separator: ","), forKey: "dashModels")
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
        sortColumn = .cost
        sortAscending = false
        projSortKey = .cost
        projSortAscending = false
        heatMetric = .tokens
        projExpanded = []
        projListOpen = false
    }

    private func parseYMD(_ s: String) -> Date? { Self.ymd.date(from: s) }
    private func ymdStr(_ d: Date) -> String { Self.ymd.string(from: d) }

    var dataRange: ClosedRange<Date>? {
        guard let first = sortedPeriods.first, let last = sortedPeriods.last,
            let e = parseYMD(first), let l = parseYMD(last)
        else { return nil }
        return e...l
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
            let earliest = parseYMD(first), let latest = parseYMD(last)
        else { return nil }
        switch range {
        case .all: return (earliest, latest)
        case .today: return (latest, latest)
        case .yesterday:
            let y = cal.date(byAdding: .day, value: -1, to: latest) ?? latest
            return (y, y)
        case .thisWeek:
            let dow = (cal.component(.weekday, from: latest) + 5) % 7
            let start = cal.date(byAdding: .day, value: -dow, to: latest) ?? latest
            return (start, latest)
        case .lastWeek:
            let dow = (cal.component(.weekday, from: latest) + 5) % 7
            let thisStart = cal.date(byAdding: .day, value: -dow, to: latest) ?? latest
            let lastEnd = cal.date(byAdding: .day, value: -1, to: thisStart) ?? thisStart
            let lastStart = cal.date(byAdding: .day, value: -6, to: lastEnd) ?? lastEnd
            return (lastStart, lastEnd)
        case .cycle(let start):
            let s = start.flatMap(parseYMD) ?? cycleStart(latest)
            return (s, min(cycleEnd(s), latest))
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
        var projAgg: [String: ProjAccum] = [:]

        var cursor = win.from
        while cursor <= win.to {
            let key = ymdStr(cursor)
            var datum = DayDatum(id: key, date: cursor, label: String(key.dropFirst(5)))
            if let day = byDate[key] {
                for (src, models) in day.bySource ?? [:] where selectedSources.contains(src) {
                    for m in models {
                        let name = m.modelName ?? "unknown"
                        guard selectedModels.contains(name) else { continue }
                        datum.input += m.inputTokens ?? 0
                        datum.output += m.outputTokens ?? 0
                        datum.cacheCreate += m.cacheCreationTokens ?? 0
                        datum.cacheRead += m.cacheReadTokens ?? 0
                        datum.cost += m.cost ?? 0
                        datum.byModel[name, default: 0] += m.tokens
                        datum.bySource[src, default: 0] += m.tokens
                        var agg = modelAgg[name] ?? (0, 0, 0, 0, 0, [])
                        agg.tokens += m.tokens
                        agg.cost += m.cost ?? 0
                        agg.input += m.inputTokens ?? 0
                        agg.output += m.outputTokens ?? 0
                        agg.cacheRead += m.cacheReadTokens ?? 0
                        agg.days.insert(key)
                        modelAgg[name] = agg
                    }
                }
                let wd = (cal.component(.weekday, from: cursor) + 6) % 7
                dowTokens[wd] += datum.tokens
                dowCost[wd] += datum.cost
                for (i, h) in (day.hours ?? []).enumerated() where i < 24 {
                    hourTok[i] += h.tokens ?? 0
                    hourCost[i] += h.cost ?? 0
                }
                for p in day.projects ?? [] {
                    let name = p.projectName ?? "unknown"
                    var a = projAgg[name] ?? ProjAccum()
                    a.absorb(p, period: key)
                    projAgg[name] = a
                }
            }
            rows.append(datum)
            cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? win.to.addingTimeInterval(1)
            if cursor <= win.from { break }
        }
        series = rows

        let totalCost = modelAgg.values.reduce(0) { $0 + $1.cost }
        var totals = modelAgg.map { name, a in
            ModelTotal(
                id: name, model: name, tokens: a.tokens, cost: a.cost, input: a.input,
                output: a.output, cacheRead: a.cacheRead, days: a.days.count,
                share: totalCost > 0 ? a.cost / totalCost : 0)
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

        projectTree = buildProjectTree(projAgg)
        projects = projectTree.map {
            ProjectAgg(id: $0.id, name: $0.name, tokens: $0.tokens, cost: $0.cost, share: $0.share)
        }
        .sorted { $0.tokens > $1.tokens }

        buildKPIs(rows: rows, totalCost: totalCost)
        buildMeta(from: fromStr, to: toStr)
        let key =
            "\(selectedSources.sorted().joined(separator: ","))|"
            + "\(selectedModels.sorted().joined(separator: ","))|\(ingestStamp)"
        if key != calendarKey {
            calendarKey = key
            buildCalendar(data: data)
        }
        rebuildChartData()
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

    private struct ChatAcc {
        var title = ""
        var tokens = 0.0
        var cost = 0.0
        var source = ""
        var lastActive = ""
        var firstTs = 0.0
        var lastTs = 0.0
        var days = Set<String>()

        mutating func merge(_ c: DashUsage.Chat, period: String) {
            tokens += c.tokens ?? 0
            cost += c.cost ?? 0
            if let s = c.source, !s.isEmpty { source = s }
            if let t = c.title, !t.isEmpty { title = t }
            if period > lastActive { lastActive = period }
            if let f = c.firstTs, f > 0, firstTs == 0 || f < firstTs { firstTs = f }
            if let l = c.lastTs, l > lastTs { lastTs = l }
            if (c.tokens ?? 0) > 0 || (c.cost ?? 0) > 0 { days.insert(period) }
        }

        var dur: Double { firstTs > 0 && lastTs > firstTs ? lastTs - firstTs : 0 }
    }

    private struct ProjAccum {
        var main: [String: ChatAcc] = [:]
        var wts: [String: [String: ChatAcc]] = [:]
        var fallbackTokens = 0.0
        var fallbackCost = 0.0
        var fallbackDays = Set<String>()

        mutating func absorb(_ p: DashUsage.Project, period: String) {
            let mainChats = p.chats ?? []
            let worktrees = p.worktrees ?? []
            let tokened = { (c: DashUsage.Chat) in (c.tokens ?? 0) > 0 || (c.cost ?? 0) > 0 }
            let hasTokenedChat =
                mainChats.contains(where: tokened)
                || worktrees.contains { ($0.chats ?? []).contains(where: tokened) }
            if !hasTokenedChat, (p.tokens ?? 0) > 0 || (p.cost ?? 0) > 0 {
                fallbackTokens += p.tokens ?? 0
                fallbackCost += p.cost ?? 0
                fallbackDays.insert(period)
            }
            for c in mainChats {
                main[c.id ?? "", default: ChatAcc()].merge(c, period: period)
            }
            for wt in worktrees {
                for c in wt.chats ?? [] {
                    wts[wt.name ?? "", default: [:]][c.id ?? "", default: ChatAcc()]
                        .merge(c, period: period)
                }
            }
        }
    }

    private func buildProjectTree(_ agg: [String: ProjAccum]) -> [ProjTreeRow] {
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

        var rows: [ProjTreeRow] = []
        for (name, a) in agg {
            let mainChats = chatRows(a.main)
            let worktrees: [ProjWorktree] = a.wts.compactMap { wtName, chatsAcc in
                let chats = chatRows(chatsAcc)
                guard !chats.isEmpty else { return nil }
                return ProjWorktree(
                    id: "wt:\(name)::\(wtName)", name: wtName,
                    tokens: chats.reduce(0) { $0 + $1.tokens },
                    cost: chats.reduce(0) { $0 + $1.cost },
                    days: daysOf(chats).count,
                    dur: chats.reduce(0) { $0 + $1.dur },
                    lastActive: chats.map(\.lastActive).max() ?? "",
                    chats: chats)
            }
            .sorted { ($0.tokens, $1.name) > ($1.tokens, $0.name) }
            guard !mainChats.isEmpty || !worktrees.isEmpty || a.fallbackTokens > 0 else {
                continue
            }
            let allDays = daysOf(mainChats + worktrees.flatMap(\.chats)).union(a.fallbackDays)
            let lastActive =
                (mainChats.map(\.lastActive) + worktrees.map(\.lastActive)
                + a.fallbackDays.sorted()).max() ?? ""
            rows.append(
                ProjTreeRow(
                    id: "proj:\(name)", name: name,
                    tokens: mainChats.reduce(0) { $0 + $1.tokens }
                        + worktrees.reduce(0) { $0 + $1.tokens } + a.fallbackTokens,
                    cost: mainChats.reduce(0) { $0 + $1.cost }
                        + worktrees.reduce(0) { $0 + $1.cost } + a.fallbackCost,
                    days: allDays.count,
                    dur: mainChats.reduce(0) { $0 + $1.dur } + worktrees.reduce(0) { $0 + $1.dur },
                    lastActive: lastActive,
                    chats: mainChats, worktrees: worktrees))
        }

        let totalCost = rows.reduce(0) { $0 + $1.cost }
        if totalCost > 0 {
            rows = rows.map { row in
                var r = row
                r.share = row.cost / totalCost
                r.chats = row.chats.map {
                    var c = $0; c.share = c.cost / totalCost; return c
                }
                r.worktrees = row.worktrees.map { wt in
                    var w = wt
                    w.share = wt.cost / totalCost
                    w.chats = wt.chats.map {
                        var c = $0; c.share = c.cost / totalCost; return c
                    }
                    return w
                }
                return r
            }
        }
        return sortTree(rows)
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
            r.chats = row.chats.sorted(by: projLess)
            r.worktrees = row.worktrees.map { wt in
                var w = wt
                w.chats = wt.chats.sorted(by: projLess)
                return w
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
        let cacheRate = (cacheRead + input) > 0 ? cacheRead / (cacheRead + input) : 0
        let top = modelTotals.max { $0.cost < $1.cost }

        var out: [KPI] = [
            KPI(
                label: "Total tokens", value: DashFmt.tokens(totalTokens),
                sub: "\(DashFmt.usd(totalCost)) · \(active.count) active days", hot: true,
                sensitiveSub: true, usageValue: true),
            KPI(
                label: "Total cost", value: DashFmt.usd(totalCost),
                sub: "\(DashFmt.tokensFull(totalTokens)) tokens", sensitiveValue: true,
                usageSub: true),
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
                    label: "Top model", value: DashFmt.shortModel(top.model),
                    sub: "\(DashFmt.usd(top.cost)) · \(DashFmt.pct(top.share))",
                    sensitiveSub: true))
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

    private func buildCalendar(data: DashUsage) {
        let today = cal.startOfDay(for: Date())
        var detail: [String: HeatDay] = [:]
        for dayRow in data.daily {
            guard let d = parseYMD(dayRow.period) else { continue }
            var h = HeatDay(date: d)
            var modelTok: [String: Double] = [:]
            var srcTok: [String: Double] = [:]
            for (src, models) in dayRow.bySource ?? [:] where selectedSources.contains(src) {
                for m in models {
                    let name = m.modelName ?? "unknown"
                    guard selectedModels.contains(name) else { continue }
                    h.input += m.inputTokens ?? 0
                    h.output += m.outputTokens ?? 0
                    h.cacheCreate += m.cacheCreationTokens ?? 0
                    h.cacheRead += m.cacheReadTokens ?? 0
                    h.cost += m.cost ?? 0
                    modelTok[name, default: 0] += m.tokens
                    srcTok[src, default: 0] += m.tokens
                }
            }
            h.tokens = h.input + h.output + h.cacheCreate + h.cacheRead
            h.models = modelTok.sorted { $0.value > $1.value }.map {
                NamedValue(id: $0.key, name: DashFmt.shortModel($0.key), value: $0.value)
            }
            h.sources = srcTok.sorted { $0.value > $1.value }.map {
                NamedValue(id: $0.key, name: sourceLabel($0.key), value: $0.value)
            }
            var projTok: [String: Double] = [:]
            var chats = 0
            for p in dayRow.projects ?? [] {
                projTok[p.projectName ?? "unknown", default: 0] += p.tokens ?? 0
                var wtChats = 0
                for wt in p.worktrees ?? [] {
                    wtChats += wt.chats?.count ?? 0
                }
                chats += (p.chats?.count ?? 0) + wtChats
            }
            h.projects = projTok.sorted { $0.value > $1.value }.map {
                NamedValue(id: $0.key, name: $0.key, value: $0.value)
            }
            h.projCount = projTok.count
            h.chatCount = chats
            for (i, hr) in (dayRow.hours ?? []).enumerated() where i < 24 {
                let t = hr.tokens ?? 0
                if t > h.peakTokens {
                    h.peakTokens = t
                    h.peakHour = i
                }
            }
            detail[dayRow.period] = h
        }
        heatDetail = detail

        var day = today
        if let first = sortedPeriods.first, let firstDate = parseYMD(first) {
            let start = cal.startOfDay(for: firstDate)
            let dow = (cal.component(.weekday, from: start) + 5) % 7
            day = cal.date(byAdding: .day, value: -dow, to: start) ?? start
        }
        var points: [DayPoint] = []
        while day <= today {
            let key = ymdStr(day)
            points.append(DayPoint(id: key, date: day, cost: detail[key]?.cost ?? 0))
            day = cal.date(byAdding: .day, value: 1, to: day) ?? today.addingTimeInterval(1)
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
        if v >= 1_000_000_000 { return String(format: "%.2fB", v / 1_000_000_000) }
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1000 { return String(format: "%.1fk", v / 1000) }
        return String(format: "%.0f", v)
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
