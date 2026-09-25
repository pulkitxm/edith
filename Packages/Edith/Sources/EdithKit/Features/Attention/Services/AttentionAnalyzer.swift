import Foundation

public struct AttentionAnalyzer: Sendable {
    public static let sliver: TimeInterval = 1
    public static let switchDwell: TimeInterval = 10
    public static let interruptionAllowance: TimeInterval = 120
    public static let continuityGap: TimeInterval = 120
    public static let spanDays: TimeInterval = 8 * 86_400

    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func summary(
        events: [AttentionEvent], settings: AttentionSettings,
        classifications: AttentionClassifications = .init(), from: Date, to: Date,
        detailed: Bool = true
    ) -> AttentionSummary {
        let ignored = Set(settings.ignoredBundleIDs.map { $0.lowercased() })
        let prepared = events.compactMap { event -> AttentionEvent? in
            var copy = event
            if event.source == .application, let bundleID = event.bundleID {
                if ignored.contains(bundleID.lowercased()) { return nil }
                if AttentionCatalog.awayBundleIDs.contains(bundleID) { copy.presence = .locked }
            }
            return copy
        }
        var classifier = AttentionClassifier(settings: settings, classifications: classifications)
        var builder = AttentionSummaryBuilder(
            settings: settings, calendar: calendar, from: from, to: to, detailed: detailed)
        for interval in resolvedPrimaryIntervals(events: prepared, from: from, to: to) {
            if interval.presence == .active {
                builder.addActive(interval, classifier.classify(interval))
            } else {
                builder.addInactive(interval)
            }
        }
        builder.addAgents(prepared.filter { $0.source == .agent })
        if detailed {
            builder.music = musicSummary(events: prepared, from: from, to: to)
        }
        return builder.finish()
    }

    func musicSummary(
        events: [AttentionEvent], from: Date, to: Date
    ) -> [AttentionMusicSummary] {
        var totals: [String: AttentionMusicSummary] = [:]
        for event in events where event.source == .media {
            guard let clipped = event.clipped(from: from, to: to), let media = clipped.media,
                media.playing, media.kind == "audio"
            else { continue }
            let id = [media.service, media.artist ?? "", media.album ?? "", media.title]
                .joined(separator: "\u{1F}")
            if var existing = totals[id] {
                existing.duration += clipped.duration
                totals[id] = existing
            } else {
                totals[id] = AttentionMusicSummary(
                    id: id, title: media.title, artist: media.artist, album: media.album,
                    service: media.service, duration: clipped.duration)
            }
        }
        return totals.values.sorted { $0.duration > $1.duration }
    }
}

private struct AttentionEntityAccumulator {
    var entity: AttentionEntity
    var sources: [String: (source: AttentionCategorySource, confidence: Double?)] = [:]
    var details: [String: AttentionDetail] = [:]
}

private struct AttentionVisit {
    var entityID: String
    var name: String
    var start: Date
    var end: Date
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

private struct AttentionFocusRun {
    var start: Date
    var lastFocusEnd: Date
    var focused: TimeInterval = 0
    var interruption: TimeInterval = 0
    var interruptions = 0
    var interrupted = false
    var names: [String: TimeInterval] = [:]
}

struct AttentionSummaryBuilder {
    let settings: AttentionSettings
    let calendar: Calendar
    let from: Date
    let to: Date
    let detailed: Bool
    var music: [AttentionMusicSummary] = []

    private var active: TimeInterval = 0
    private var idle: TimeInterval = 0
    private var kinds: [String: TimeInterval] = [:]
    private var categoryTotals: [String: TimeInterval] = [:]
    private var entities: [String: AttentionEntityAccumulator] = [:]
    private var days: [Date: AttentionDayTotal] = [:]
    private var hours: [Int: AttentionHourCell] = [:]
    private var spans: [AttentionSpan] = []
    private var dimensions: [String: [String: AttentionBreakdownRow]] = [:]
    private var signals = AttentionSignals()
    private var visit: AttentionVisit?
    private var lastActiveEnd: Date?
    private var anchor: (entityID: String, name: String)?
    private var stretches: [TimeInterval] = []
    private var switches = 0
    private var transitions: [String: AttentionTransition] = [:]
    private var focusRun: AttentionFocusRun?
    private var focusCursor: Date?
    private var focusBlocks: [AttentionFocusBlock] = []
    private var attended: [String: [String: TimeInterval]] = [:]
    private var attendedTotal: TimeInterval = 0
    private var agentSummary = AttentionAgentSummary()
    private let spanGap: TimeInterval
    private let bin: TimeInterval

    init(settings: AttentionSettings, calendar: Calendar, from: Date, to: Date, detailed: Bool) {
        self.settings = settings
        self.calendar = calendar
        self.from = from
        self.to = to
        self.detailed = detailed
        let length = to.timeIntervalSince(from)
        spanGap = length > 129_600 ? 120 : 30
        bin = length <= 129_600 ? 900 : length <= AttentionAnalyzer.spanDays ? 3_600 : 86_400
    }

    mutating func addActive(_ interval: AttentionEvent, _ classification: AttentionClassification) {
        let duration = interval.duration
        let category = settings.category(classification.categoryID)
        active += duration
        kinds[category.kind.rawValue, default: 0] += duration
        categoryTotals[category.id, default: 0] += duration
        signals = signals.adding(interval.signals)
        let interactions = interval.signals?.interactions ?? 0
        Self.splitByHour(interval.startedAt, interval.endedAt, calendar: calendar) { start, seconds in
            let day = calendar.startOfDay(for: start)
            var total = days[day] ?? AttentionDayTotal(day: day)
            total.active += seconds
            total.categories[category.id, default: 0] += seconds
            days[day] = total
            let weekday = calendar.component(.weekday, from: start)
            let hour = calendar.component(.hour, from: start)
            var cell = hours[weekday * 24 + hour] ?? AttentionHourCell(weekday: weekday, hour: hour)
            cell.kinds[category.kind.rawValue, default: 0] += seconds
            hours[weekday * 24 + hour] = cell
        }
        trackVisit(interval, classification)
        trackFocus(
            start: interval.startedAt, end: interval.endedAt, isFocus: category.kind == .focus,
            name: classification.entityName)
        trackAttendance(interval)
        guard detailed else { return }
        accumulateEntity(interval, classification, category: category)
        accumulateDimensions(interval, classification, category: category)
        if to.timeIntervalSince(from) <= AttentionAnalyzer.spanDays {
            appendSpan(interval, classification, interactions: interactions)
        }
    }

    mutating func addInactive(_ interval: AttentionEvent) {
        idle += interval.duration
        closeVisit()
        anchor = nil
        lastActiveEnd = nil
        trackFocus(
            start: interval.startedAt, end: interval.endedAt, isFocus: false, name: "")
    }

    mutating func addAgents(_ events: [AttentionEvent]) {
        var machines: [String: AttentionAgentTotal] = [:]
        var kindTotals: [String: AttentionAgentTotal] = [:]
        var projects: [String: AttentionAgentTotal] = [:]
        var sessions: [String: AttentionAgentSession] = [:]
        var sessionKeys: [String: Set<String>] = [:]
        var bins: [Date: TimeInterval] = [:]
        var edges: [(Date, Int)] = []
        var summary = AttentionAgentSummary()
        for event in events {
            guard let clipped = event.clipped(from: from, to: to) else { continue }
            let duration = clipped.duration
            let working = clipped.tag(AttentionTag.status) != "blocked"
            let machine = clipped.tag(AttentionTag.machine) ?? "Unknown machine"
            let kind = clipped.tag(AttentionTag.agent) ?? "Agent"
            let project = clipped.tag(AttentionTag.project)
            let sessionID = clipped.tag(AttentionTag.session) ?? clipped.id
            func add(_ totals: inout [String: AttentionAgentTotal], _ key: String) {
                var total = totals[key] ?? AttentionAgentTotal(key: key)
                if working { total.working += duration } else { total.blocked += duration }
                totals[key] = total
                sessionKeys[key, default: []].insert(sessionID)
            }
            add(&machines, "m:" + machine)
            add(&kindTotals, "k:" + kind)
            if let project { add(&projects, "p:" + project) }
            var session =
                sessions[sessionID]
                ?? AttentionAgentSession(
                    id: sessionID, title: clipped.windowTitle ?? kind, machine: machine,
                    kind: kind, project: project, working: 0, blocked: 0,
                    lastSeen: clipped.endedAt)
            if working { session.working += duration } else { session.blocked += duration }
            session.lastSeen = max(session.lastSeen, clipped.endedAt)
            if let title = clipped.windowTitle, !title.isEmpty { session.title = title }
            sessions[sessionID] = session
            if working {
                summary.working += duration
                edges.append((clipped.startedAt, 1))
                edges.append((clipped.endedAt, -1))
                Self.splitByHour(clipped.startedAt, clipped.endedAt, calendar: calendar) { start, seconds in
                    let day = calendar.startOfDay(for: start)
                    var total = days[day] ?? AttentionDayTotal(day: day)
                    total.agentWorking += seconds
                    days[day] = total
                }
                Self.splitByBin(clipped.startedAt, clipped.endedAt, bin: bin, calendar: calendar) { start, seconds in
                    bins[start, default: 0] += seconds
                }
            } else {
                summary.blocked += duration
            }
        }
        var running = 0
        for edge in edges.sorted(by: { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }) {
            running += edge.1
            summary.peakConcurrent = max(summary.peakConcurrent, running)
        }
        func finalize(_ totals: [String: AttentionAgentTotal], dimension: String)
            -> [AttentionAgentTotal]
        {
            totals.map { key, value in
                var total = value
                total.key = String(key.dropFirst(2))
                total.sessions = sessionKeys[key]?.count ?? 0
                total.attended = attended[dimension]?[total.key] ?? 0
                return total
            }
            .sorted { $0.working + $0.blocked > $1.working + $1.blocked }
        }
        summary.machines = finalize(machines, dimension: AttentionTag.machine)
        summary.kinds = finalize(kindTotals, dimension: AttentionTag.agent)
        summary.projects = finalize(projects, dimension: AttentionTag.project)
        summary.sessions = sessions.values.sorted { $0.working > $1.working }
        summary.attended = attendedTotal
        if !bins.isEmpty {
            var cursor = binStart(from)
            var points: [AttentionConcurrencyPoint] = []
            while cursor < to {
                let working = bins[cursor] ?? 0
                points.append(
                    AttentionConcurrencyPoint(
                        start: cursor, working: working / bin,
                        attention: attentionBins[cursor] ?? 0))
                cursor = cursor.addingTimeInterval(bin)
            }
            summary.concurrency = points
        }
        agentSummary = summary
    }

    private var attentionBins: [Date: TimeInterval] = [:]

    mutating func finish() -> AttentionSummary {
        closeVisit()
        closeFocus()
        var dayTotals: [AttentionDayTotal] = []
        var cursor = calendar.startOfDay(for: from)
        while cursor < to {
            dayTotals.append(days[cursor] ?? AttentionDayTotal(day: cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        for index in dayTotals.indices {
            dayTotals[index].switches = daySwitches[dayTotals[index].day] ?? 0
        }
        let sorted = stretches.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        var entityList = entities.values.map { accumulator -> AttentionEntity in
            var entity = accumulator.entity
            let dominant =
                entity.categoryDurations.max { $0.value < $1.value }?.key
                ?? AttentionCatalog.unclassified
            entity.category = settings.category(dominant)
            let source = accumulator.sources[dominant]
            entity.categorySource = source?.source ?? .none
            entity.confidence = source?.confidence
            entity.details = accumulator.details.values.sorted { $0.duration > $1.duration }
                .prefix(12).map { $0 }
            return entity
        }
        entityList.sort { $0.duration > $1.duration }
        let dimensionList = dimensions.map { key, rows in
            let values = rows.values.sorted { $0.duration > $1.duration }
            return AttentionDimension(
                key: key, rows: Array(values.prefix(80)),
                total: values.reduce(0) { $0 + $1.duration })
        }
        .sorted { lhs, rhs in
            let order = [AttentionDimension.entity, AttentionDimension.title, AttentionDimension.url]
                + AttentionTag.dimensions
            return (order.firstIndex(of: lhs.key) ?? 99) < (order.firstIndex(of: rhs.key) ?? 99)
        }
        var spanList = spans
        if to.timeIntervalSince(from) > 129_600 {
            spanList.removeAll { $0.duration < 30 }
        }
        return AttentionSummary(
            from: from, to: to, activeDuration: active, idleDuration: idle, kinds: kinds,
            contextSwitches: switches, medianStretch: median,
            longestStretch: sorted.last ?? 0, entities: Array(entityList.prefix(400)),
            categories: categoryTotals.map {
                AttentionCategoryTotal(category: settings.category($0.key), duration: $0.value)
            }.sorted { $0.duration > $1.duration },
            music: music, days: dayTotals,
            hours: hours.values.sorted { $0.id < $1.id },
            spans: Array(spanList.prefix(8_000)), focusBlocks: focusBlocks,
            transitions: transitions.values.sorted { $0.count > $1.count }.prefix(10).map { $0 },
            dimensions: dimensionList, agents: agentSummary, signals: signals)
    }

    private var daySwitches: [Date: Int] = [:]

    private mutating func trackVisit(
        _ interval: AttentionEvent, _ classification: AttentionClassification
    ) {
        if let lastActiveEnd,
            interval.startedAt.timeIntervalSince(lastActiveEnd) > AttentionAnalyzer.continuityGap
        {
            closeVisit()
            anchor = nil
        }
        lastActiveEnd = interval.endedAt
        if var current = visit, current.entityID == classification.entityID,
            interval.startedAt.timeIntervalSince(current.end) <= 5
        {
            current.end = interval.endedAt
            visit = current
            return
        }
        closeVisit()
        visit = AttentionVisit(
            entityID: classification.entityID, name: classification.entityName,
            start: interval.startedAt, end: interval.endedAt)
        if detailed {
            var accumulator = entities[classification.entityID]
            accumulator?.entity.visits += 1
            if let accumulator { entities[classification.entityID] = accumulator }
        }
    }

    private mutating func closeVisit() {
        guard let current = visit else { return }
        visit = nil
        stretches.append(current.duration)
        guard current.duration >= AttentionAnalyzer.switchDwell else { return }
        if let anchor, anchor.entityID != current.entityID {
            switches += 1
            daySwitches[calendar.startOfDay(for: current.start), default: 0] += 1
            let key = anchor.name + "\u{1F}" + current.name
            var transition =
                transitions[key] ?? AttentionTransition(from: anchor.name, to: current.name, count: 0)
            transition.count += 1
            transitions[key] = transition
        }
        anchor = (current.entityID, current.name)
    }

    private mutating func trackFocus(start: Date, end: Date, isFocus: Bool, name: String) {
        if let cursor = focusCursor, start > cursor {
            interrupt(start.timeIntervalSince(cursor))
        }
        focusCursor = max(focusCursor ?? end, end)
        let duration = end.timeIntervalSince(start)
        guard isFocus else {
            interrupt(duration)
            return
        }
        var run = focusRun ?? AttentionFocusRun(start: start, lastFocusEnd: end)
        if run.interrupted {
            run.interruptions += 1
            run.interrupted = false
        }
        run.focused += duration
        run.lastFocusEnd = end
        run.interruption = 0
        run.names[name, default: 0] += duration
        focusRun = run
    }

    private mutating func interrupt(_ duration: TimeInterval) {
        guard var run = focusRun else { return }
        run.interruption += duration
        run.interrupted = true
        if run.interruption > AttentionAnalyzer.interruptionAllowance {
            focusRun = run
            closeFocus()
        } else {
            focusRun = run
        }
    }

    private mutating func closeFocus() {
        guard let run = focusRun else { return }
        focusRun = nil
        guard run.focused >= settings.focusBlockMinimum else { return }
        focusBlocks.append(
            AttentionFocusBlock(
                start: run.start, end: run.lastFocusEnd, focused: run.focused,
                interruptions: run.interruptions,
                topNames: run.names.sorted { $0.value > $1.value }.prefix(3).map(\.key)))
    }

    private mutating func trackAttendance(_ interval: AttentionEvent) {
        Self.splitByBin(interval.startedAt, interval.endedAt, bin: bin, calendar: calendar) { start, seconds in
            attentionBins[start, default: 0] += seconds
        }
        guard let tags = interval.tags, tags[AttentionTag.machine] != nil else { return }
        attendedTotal += interval.duration
        for key in [AttentionTag.machine, AttentionTag.agent, AttentionTag.project] {
            if let value = tags[key] {
                attended[key, default: [:]][value, default: 0] += interval.duration
            }
        }
    }

    private mutating func accumulateEntity(
        _ interval: AttentionEvent, _ classification: AttentionClassification,
        category: AttentionCategory
    ) {
        let duration = interval.duration
        var accumulator =
            entities[classification.entityID]
            ?? AttentionEntityAccumulator(
                entity: AttentionEntity(
                    id: classification.entityID, name: classification.entityName,
                    category: category, source: interval.source, duration: 0,
                    domain: classification.domain, visits: 1))
        accumulator.entity.duration += duration
        accumulator.entity.categoryDurations[category.id, default: 0] += duration
        accumulator.entity.signals = accumulator.entity.signals.adding(interval.signals)
        if interval.source == .application, let bundleID = interval.bundleID {
            accumulator.entity.bundleID = bundleID
        }
        if let favicon = interval.faviconURL { accumulator.entity.faviconURL = favicon }
        if accumulator.entity.domain == nil { accumulator.entity.domain = classification.domain }
        if accumulator.sources[category.id] == nil {
            accumulator.sources[category.id] = (classification.source, classification.confidence)
        }
        if let name = detailName(interval) {
            var detail =
                accumulator.details[name]
                ?? AttentionDetail(
                    name: name, url: interval.url, duration: 0, categoryID: category.id)
            detail.duration += duration
            accumulator.details[name] = detail
        }
        entities[classification.entityID] = accumulator
    }

    private func detailName(_ interval: AttentionEvent) -> String? {
        if let title = interval.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty
        {
            return String(title.prefix(200))
        }
        return AttentionText.location(interval.url)
    }

    private mutating func accumulateDimensions(
        _ interval: AttentionEvent, _ classification: AttentionClassification,
        category: AttentionCategory
    ) {
        var keys: [(String, String)] = [(AttentionDimension.entity, classification.entityName)]
        if let title = detailName(interval), interval.windowTitle != nil {
            keys.append((AttentionDimension.title, title))
        }
        if let location = AttentionText.location(interval.url) {
            keys.append((AttentionDimension.url, location))
        }
        for key in AttentionTag.dimensions {
            if let value = interval.tags?[key], !value.isEmpty { keys.append((key, value)) }
        }
        for (dimension, value) in keys {
            var row = dimensions[dimension]?[value] ?? AttentionBreakdownRow(key: value)
            row.duration += interval.duration
            row.categories[category.id, default: 0] += interval.duration
            row.interactions += interval.signals?.interactions ?? 0
            if row.entityNames.count < 3, !row.entityNames.contains(classification.entityName) {
                row.entityNames.append(classification.entityName)
            }
            dimensions[dimension, default: [:]][value] = row
        }
    }

    private mutating func appendSpan(
        _ interval: AttentionEvent, _ classification: AttentionClassification, interactions: Int
    ) {
        if var last = spans.last, last.entityID == classification.entityID,
            last.categoryID == classification.categoryID,
            interval.startedAt.timeIntervalSince(last.end) <= spanGap
        {
            last.end = max(last.end, interval.endedAt)
            last.interactions += interactions
            if last.detail == nil { last.detail = interval.windowTitle }
            spans[spans.count - 1] = last
            return
        }
        spans.append(
            AttentionSpan(
                start: interval.startedAt, end: interval.endedAt,
                entityID: classification.entityID, name: classification.entityName,
                categoryID: classification.categoryID,
                detail: interval.windowTitle.map { String($0.prefix(160)) } ?? interval.domain,
                tags: interval.tags, interactions: interactions))
    }

    private func binStart(_ date: Date) -> Date {
        Self.binStart(date, bin: bin, calendar: calendar)
    }

    private static func binStart(_ date: Date, bin: TimeInterval, calendar: Calendar) -> Date {
        if bin >= 86_400 { return calendar.startOfDay(for: date) }
        let dayStart = calendar.startOfDay(for: date)
        let offset = date.timeIntervalSince(dayStart)
        return dayStart.addingTimeInterval((offset / bin).rounded(.down) * bin)
    }

    private static func splitByBin(
        _ start: Date, _ end: Date, bin: TimeInterval, calendar: Calendar,
        _ body: (Date, TimeInterval) -> Void
    ) {
        var cursor = start
        while cursor < end {
            let begin = binStart(cursor, bin: bin, calendar: calendar)
            let next =
                bin >= 86_400
                ? (calendar.date(byAdding: .day, value: 1, to: begin) ?? end)
                : begin.addingTimeInterval(bin)
            let stop = min(end, next)
            body(begin, stop.timeIntervalSince(cursor))
            cursor = stop
        }
    }

    private static func splitByHour(
        _ start: Date, _ end: Date, calendar: Calendar, _ body: (Date, TimeInterval) -> Void
    ) {
        var cursor = start
        while cursor < end {
            let hourEnd = calendar.dateInterval(of: .hour, for: cursor)?.end ?? end
            let stop = min(end, hourEnd)
            body(cursor, stop.timeIntervalSince(cursor))
            cursor = stop
        }
    }
}
