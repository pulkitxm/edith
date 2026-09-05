import Foundation

public struct AttentionAnalyzer: Sendable {
    public init() {}

    public func summary(
        events: [AttentionEvent], settings: AttentionSettings, from: Date, to: Date
    ) -> AttentionSummary {
        let primary = resolvedPrimaryIntervals(events: events, from: from, to: to)
        let categoriesByID = Dictionary(
            settings.categories.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let fallback = categoriesByID["unclassified"] ?? AttentionSettings.defaultCategories.last!
        var totals: [String: AttentionEntity] = [:]
        var activeDuration: TimeInterval = 0
        var idleDuration: TimeInterval = 0
        var focusedDuration: TimeInterval = 0
        var communicationDuration: TimeInterval = 0
        var entertainmentDuration: TimeInterval = 0
        var contextSwitches = 0
        var previousID: String?

        for event in primary {
            let duration = event.duration
            if event.presence == .active {
                activeDuration += duration
            } else {
                idleDuration += duration
            }
            let resolved = resolve(
                event: event, settings: settings, categoriesByID: categoriesByID,
                fallback: fallback)
            if event.presence == .active {
                switch resolved.category.kind {
                case .focus: focusedDuration += duration
                case .communication: communicationDuration += duration
                case .entertainment: entertainmentDuration += duration
                case .neutral, .unclassified: break
                }
                if previousID != nil, previousID != resolved.id { contextSwitches += 1 }
                previousID = resolved.id
                if var existing = totals[resolved.id] {
                    existing.duration += duration
                    if event.source == .application {
                        existing.bundleID = event.bundleID ?? existing.bundleID
                    }
                    existing.faviconURL = event.faviconURL ?? existing.faviconURL
                    totals[resolved.id] = existing
                } else {
                    totals[resolved.id] = AttentionEntity(
                        id: resolved.id, name: resolved.name, category: resolved.category,
                        source: event.source, duration: duration,
                        bundleID: event.source == .application ? event.bundleID : nil,
                        faviconURL: event.faviconURL)
                }
            }
        }

        return AttentionSummary(
            from: from, to: to, activeDuration: activeDuration, idleDuration: idleDuration,
            focusedDuration: focusedDuration, communicationDuration: communicationDuration,
            entertainmentDuration: entertainmentDuration, contextSwitches: contextSwitches,
            entities: totals.values.sorted { $0.duration > $1.duration },
            music: musicSummary(events: events, from: from, to: to))
    }

    public func resolvedPrimaryIntervals(
        events: [AttentionEvent], from: Date, to: Date
    ) -> [AttentionEvent] {
        let candidates = events.filter(\.isPrimaryAttention).compactMap {
            $0.clipped(from: from, to: to)
        }
        let boundaries = Set(candidates.flatMap { [$0.startedAt, $0.endedAt] }).sorted()
        guard boundaries.count > 1 else { return [] }
        let slotCount = boundaries.count - 1
        var slotByTime: [Date: Int] = [:]
        slotByTime.reserveCapacity(boundaries.count)
        for (slot, time) in boundaries.enumerated() { slotByTime[time] = slot }
        let claimOrder = candidates.indices.sorted {
            let left = priority(candidates[$0])
            let right = priority(candidates[$1])
            return left == right ? $0 < $1 : left > right
        }
        var winners = [Int?](repeating: nil, count: slotCount)
        var nextOpenSlot = Array(0...slotCount)
        for candidateIndex in claimOrder {
            let candidate = candidates[candidateIndex]
            guard let low = slotByTime[candidate.startedAt],
                let high = slotByTime[candidate.endedAt]
            else { continue }
            var slot = openSlot(from: low, in: &nextOpenSlot)
            while slot < high {
                winners[slot] = candidateIndex
                nextOpenSlot[slot] = slot + 1
                slot = openSlot(from: slot + 1, in: &nextOpenSlot)
            }
        }
        var result: [AttentionEvent] = []
        for slot in 0..<slotCount {
            guard let winner = winners[slot] else { continue }
            var selected = candidates[winner]
            selected.startedAt = boundaries[slot]
            selected.duration = boundaries[slot + 1].timeIntervalSince(boundaries[slot])
            if let last = result.last, last.canMerge(with: selected, pulseTime: 0) {
                result[result.count - 1] = last.merged(with: selected)
            } else {
                result.append(selected)
            }
        }
        return result
    }

    private func openSlot(from slot: Int, in nextOpenSlot: inout [Int]) -> Int {
        var open = slot
        while nextOpenSlot[open] != open { open = nextOpenSlot[open] }
        var walker = slot
        while nextOpenSlot[walker] != walker {
            let following = nextOpenSlot[walker]
            nextOpenSlot[walker] = open
            walker = following
        }
        return open
    }

    private func priority(_ event: AttentionEvent) -> Int {
        let source = event.source == .browser ? 20 : 10
        let presence = event.presence == .active ? 2 : 1
        return source + presence
    }

    private func resolve(
        event: AttentionEvent, settings: AttentionSettings,
        categoriesByID: [String: AttentionCategory], fallback: AttentionCategory
    ) -> (id: String, name: String, category: AttentionCategory) {
        let bundleID = event.bundleID?.lowercased()
        let domain = normalizedDomain(event.domain ?? event.url)
        let rule = settings.rules.first { rule in
            rule.bundleIDs.contains { $0.lowercased() == bundleID }
                || rule.domains.contains { matches(domain: domain, rule: $0) }
        }
        if let rule {
            return ("identity:\(rule.id)", rule.name, categoriesByID[rule.categoryID] ?? fallback)
        }
        if event.source == .browser, let domain {
            return ("web:\(domain)", domain, fallback)
        }
        let name = event.appName ?? event.bundleID ?? "Unknown application"
        return ("app:\(event.bundleID ?? name)", name, fallback)
    }

    private func normalizedDomain(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let host = URL(string: raw)?.host ?? raw
        return host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private func matches(domain: String?, rule: String) -> Bool {
        guard let domain else { return false }
        let normalizedRule = rule.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: "."))
        return domain == normalizedRule || domain.hasSuffix("." + normalizedRule)
    }

    private func musicSummary(
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
