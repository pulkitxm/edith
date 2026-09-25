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
        for slot in 0..<slotCount {
            winners[slot] = winner(
                foreground: foreground[slot], claimed: claimed[slot],
                contested: contested[slot], candidates: candidates)
        }
        return (
            candidates, boundaries,
            settled(winners, boundaries: boundaries, candidates: candidates)
        )
    }

    private func identity(_ index: Int?, candidates: [AttentionEvent]) -> String? {
        guard let index else { return nil }
        let event = candidates[index]
        return [
            event.source.rawValue, event.presence.rawValue,
            event.bundleID ?? event.appName ?? "", event.domain ?? "",
            event.browserProfile ?? "", event.windowTitle ?? "", event.url ?? "",
            (event.tags ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
                .joined(separator: ","),
        ].joined(separator: "\u{1F}")
    }

    private func settled(
        _ winners: [Int?], boundaries: [Date], candidates: [AttentionEvent]
    ) -> [Int?] {
        guard winners.count > 1 else { return winners }
        var runs: [(low: Int, high: Int, key: String?, seconds: TimeInterval)] = []
        for slot in winners.indices {
            let key = identity(winners[slot], candidates: candidates)
            let seconds = boundaries[slot + 1].timeIntervalSince(boundaries[slot])
            if var last = runs.last, last.key == key {
                last.high = slot + 1
                last.seconds += seconds
                runs[runs.count - 1] = last
            } else {
                runs.append((slot, slot + 1, key, seconds))
            }
        }
        var index = 0
        while index < runs.count {
            guard runs.count > 1, runs[index].seconds < Self.sliver else {
                index += 1
                continue
            }
            let previous = index > 0 ? runs[index - 1].seconds : -1
            let following = index + 1 < runs.count ? runs[index + 1].seconds : -1
            let target = previous >= following ? index - 1 : index + 1
            runs[target].low = min(runs[target].low, runs[index].low)
            runs[target].high = max(runs[target].high, runs[index].high)
            runs[target].seconds += runs[index].seconds
            runs.remove(at: index)
            index = max(0, min(index, runs.count) - 1)
        }
        var result = winners
        for run in runs {
            let winner =
                winners[run.low..<run.high].first {
                    identity($0, candidates: candidates) == run.key
                } ?? winners[run.low]
            for slot in run.low..<run.high { result[slot] = winner }
        }
        return result
    }

    private func winner(
        foreground: Int?, claimed: Int?, contested: [Int]?, candidates: [AttentionEvent]
    ) -> Int? {
        guard let claimed else { return foreground }
        guard let foreground else { return claimed }
        let front = candidates[foreground]
        guard AttentionBrowserIdentity.isBrowser(bundleID: front.bundleID, appName: front.appName)
        else { return foreground }
        guard let contested else { return claimed }
        return corroborated(contested, candidates: candidates, window: front.windowTitle)
            ?? foreground
    }

    private func corroborated(
        _ claims: [Int], candidates: [AttentionEvent], window: String?
    ) -> Int? {
        let normalizedWindow = AttentionTitleCorrelation.normalized(window)
        guard !normalizedWindow.isEmpty else { return nil }
        var best: (score: Int, index: Int)?
        var ambiguous = false
        for index in claims {
            let page = AttentionTitleCorrelation.normalized(candidates[index].windowTitle)
            guard AttentionTitleCorrelation.corroborates(window: normalizedWindow, page: page)
            else { continue }
            let score = AttentionTitleCorrelation.overlap(normalizedWindow, page)
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
