import Foundation

extension AttentionAnalyzer {
    public func resolvedPrimaryIntervals(
        events: [AttentionEvent], from: Date, to: Date
    ) -> [AttentionEvent] {
        let resolution = resolve(events: events, from: from, to: to)
        var result: [AttentionEvent] = []
        for slot in resolution.winners.indices {
            guard let winner = resolution.winners[slot] else { continue }
            var selected = resolution.candidates[winner]
            selected.startedAt = resolution.boundaries[slot]
            selected.duration = resolution.boundaries[slot + 1].timeIntervalSince(
                resolution.boundaries[slot])
            if let last = result.last, last.canMerge(with: selected, pulseTime: 0) {
                result[result.count - 1] = last.merged(with: selected)
            } else {
                result.append(selected)
            }
        }
        return result
    }

    private func resolve(
        events: [AttentionEvent], from: Date, to: Date
    ) -> (candidates: [AttentionEvent], boundaries: [Date], winners: [Int?]) {
        let candidates = events.filter(\.isPrimaryAttention).compactMap {
            $0.clipped(from: from, to: to)
        }
        let boundaries = Set(candidates.flatMap { [$0.startedAt, $0.endedAt] }).sorted()
        guard boundaries.count > 1 else { return (candidates, boundaries, []) }
        let slotCount = boundaries.count - 1
        var slotByTime: [Date: Int] = [:]
        slotByTime.reserveCapacity(boundaries.count)
        for (slot, time) in boundaries.enumerated() { slotByTime[time] = slot }
        let applications = candidates.indices.filter { candidates[$0].source == .application }
        let browsers = candidates.indices.filter { candidates[$0].source == .browser }
        let foreground = claim(
            applications, candidates: candidates, slotByTime: slotByTime, slotCount: slotCount)
        let claimed = claim(
            browsers, candidates: candidates, slotByTime: slotByTime, slotCount: slotCount)
        let contested = contestedClaims(
            browsers, candidates: candidates, slotByTime: slotByTime, slotCount: slotCount)
        var winners = [Int?](repeating: nil, count: slotCount)
        var cache = AttentionCorroborationCache()
        for slot in 0..<slotCount {
            winners[slot] = winner(
                foreground: foreground[slot], claimed: claimed[slot],
                contested: contested[slot], candidates: candidates, cache: &cache)
        }
        return (
            candidates, boundaries,
            settled(winners, boundaries: boundaries, keys: identities(candidates))
        )
    }

    private func identities(_ candidates: [AttentionEvent]) -> [Int] {
        var interned: [String: Int] = [:]
        return candidates.map { event in
            let key = [
                event.source.rawValue, event.presence.rawValue,
                event.bundleID ?? event.appName ?? "", event.domain ?? "",
                event.browserProfile ?? "", event.windowTitle ?? "", event.url ?? "",
                (event.tags ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
                    .joined(separator: ","),
            ].joined(separator: "\u{1F}")
            if let existing = interned[key] { return existing }
            interned[key] = interned.count
            return interned.count - 1
        }
    }

    private func settled(_ winners: [Int?], boundaries: [Date], keys: [Int]) -> [Int?] {
        guard winners.count > 1 else { return winners }
        func key(_ index: Int?) -> Int { index.map { keys[$0] } ?? -1 }
        var low: [Int] = []
        var high: [Int] = []
        var runKeys: [Int] = []
        var seconds: [TimeInterval] = []
        for slot in winners.indices {
            let current = key(winners[slot])
            let length = boundaries[slot + 1].timeIntervalSince(boundaries[slot])
            if let last = runKeys.indices.last, runKeys[last] == current {
                high[last] = slot + 1
                seconds[last] += length
            } else {
                low.append(slot)
                high.append(slot + 1)
                runKeys.append(current)
                seconds.append(length)
            }
        }
        let count = runKeys.count
        var previous = Array(-1..<(count - 1))
        var next = Array(1...count)
        var removed = [Bool](repeating: false, count: count)
        var alive = count
        var index = 0
        while index >= 0, index < count {
            guard alive > 1, seconds[index] < Self.sliver else {
                index = next[index]
                continue
            }
            let before = previous[index]
            let after = next[index] < count ? next[index] : -1
            let beforeSeconds = before >= 0 ? seconds[before] : -1
            let afterSeconds = after >= 0 ? seconds[after] : -1
            let target = beforeSeconds >= afterSeconds ? before : after
            low[target] = min(low[target], low[index])
            high[target] = max(high[target], high[index])
            seconds[target] += seconds[index]
            if before >= 0 { next[before] = next[index] }
            if after >= 0 { previous[after] = before }
            removed[index] = true
            alive -= 1
            index = before >= 0 ? before : after
        }
        var result = winners
        for node in 0..<count where !removed[node] {
            let expected = runKeys[node]
            let winner =
                winners[low[node]..<high[node]].first { key($0) == expected } ?? winners[low[node]]
            for slot in low[node]..<high[node] { result[slot] = winner }
        }
        return result
    }

    private func winner(
        foreground: Int?, claimed: Int?, contested: [Int]?, candidates: [AttentionEvent],
        cache: inout AttentionCorroborationCache
    ) -> Int? {
        guard let claimed else { return foreground }
        guard let foreground else { return claimed }
        let front = candidates[foreground]
        guard AttentionBrowserIdentity.isBrowser(bundleID: front.bundleID, appName: front.appName)
        else { return foreground }
        guard let contested else { return claimed }
        return corroborated(contested, candidates: candidates, window: foreground, cache: &cache)
            ?? foreground
    }

    private func corroborated(
        _ claims: [Int], candidates: [AttentionEvent], window: Int,
        cache: inout AttentionCorroborationCache
    ) -> Int? {
        guard !cache.title(window, candidates: candidates).isEmpty else { return nil }
        var best: (score: Int, index: Int)?
        var ambiguous = false
        for index in claims {
            guard let score = cache.score(window: window, page: index, candidates: candidates)
            else { continue }
            guard let current = best else {
                best = (score, index)
                continue
            }
            if score > current.score {
                best = (score, index)
                ambiguous = false
            } else if score == current.score,
                !sameIdentity(candidates[current.index], candidates[index])
            {
                ambiguous = true
            }
        }
        guard let best, !ambiguous else { return nil }
        return best.index
    }

    private func sameIdentity(_ left: AttentionEvent, _ right: AttentionEvent) -> Bool {
        left.domain == right.domain && left.browserProfile == right.browserProfile
    }

    private func claim(
        _ indices: [Int], candidates: [AttentionEvent], slotByTime: [Date: Int], slotCount: Int
    ) -> [Int?] {
        var winners = [Int?](repeating: nil, count: slotCount)
        var nextOpenSlot = Array(0...slotCount)
        let order = indices.sorted {
            let left = priority(candidates[$0])
            let right = priority(candidates[$1])
            return left == right ? $0 < $1 : left > right
        }
        for candidateIndex in order {
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
        return winners
    }

    private func contestedClaims(
        _ indices: [Int], candidates: [AttentionEvent], slotByTime: [Date: Int], slotCount: Int
    ) -> [[Int]?] {
        var spans: [(low: Int, high: Int, index: Int)] = []
        spans.reserveCapacity(indices.count)
        var depth = [Int](repeating: 0, count: slotCount + 1)
        for candidateIndex in indices {
            let candidate = candidates[candidateIndex]
            guard let low = slotByTime[candidate.startedAt],
                let high = slotByTime[candidate.endedAt], low < high
            else { continue }
            spans.append((low, high, candidateIndex))
            depth[low] += 1
            depth[high] -= 1
        }
        var running = 0
        var overlapping = [Bool](repeating: false, count: slotCount)
        for slot in 0..<slotCount {
            running += depth[slot]
            overlapping[slot] = running > 1
        }
        guard overlapping.contains(true) else { return [[Int]?](repeating: nil, count: slotCount) }
        var claims = [[Int]?](repeating: nil, count: slotCount)
        for span in spans {
            for slot in span.low..<span.high where overlapping[slot] {
                claims[slot] = (claims[slot] ?? []) + [span.index]
            }
        }
        return claims
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
        event.presence == .active ? 2 : 1
    }
}

struct AttentionCorroborationCache {
    private var titles: [Int: String] = [:]
    private var scores: [String: [String: Int?]] = [:]

    mutating func title(_ index: Int, candidates: [AttentionEvent]) -> String {
        if let cached = titles[index] { return cached }
        let value = AttentionTitleCorrelation.normalized(candidates[index].windowTitle)
        titles[index] = value
        return value
    }

    mutating func score(window: Int, page: Int, candidates: [AttentionEvent]) -> Int? {
        let windowTitle = title(window, candidates: candidates)
        let pageTitle = title(page, candidates: candidates)
        if let cached = scores[windowTitle]?[pageTitle] { return cached }
        let shared = AttentionTitleCorrelation.overlap(windowTitle, pageTitle)
        let value: Int? =
            AttentionTitleCorrelation.corroborates(
                shared: shared, window: windowTitle, page: pageTitle) ? shared : nil
        scores[windowTitle, default: [:]][pageTitle] = .some(value)
        return value
    }
}
