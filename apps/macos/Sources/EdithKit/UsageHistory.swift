import Foundation

public enum UsageHistory {
    public static func merge(local: Data?, cloud: Data?) -> Data? {
        guard let local else { return cloud }
        guard let cloud else { return local }
        guard let l = decode(local) else { return cloud }
        guard let c = decode(cloud) else { return local }

        var best: [String: [String: Any]] = [:]
        for day in daily(c) {
            guard let p = day["period"] as? String else { continue }
            best[p] = day
        }
        for day in daily(l) {
            guard let p = day["period"] as? String else { continue }
            if let cur = best[p], dayTokens(cur) > dayTokens(day) { continue }
            best[p] = day
        }
        let mergedDaily = best.keys.sorted().compactMap { best[$0] }

        var out = l
        out["schemaVersion"] = max(intOf(l["schemaVersion"]), intOf(c["schemaVersion"]))
        out["daily"] = mergedDaily
        out["sources"] = union(strings(l["sources"]), strings(c["sources"]))
        out["defaultSources"] = union(strings(l["defaultSources"]), strings(c["defaultSources"]))
        var meta = c["sourceMeta"] as? [String: Any] ?? [:]
        for (k, v) in l["sourceMeta"] as? [String: Any] ?? [:] { meta[k] = v }
        out["sourceMeta"] = meta
        out["sessions"] = mergeSessions(l["sessions"], c["sessions"])
        out["totals"] = totals(of: mergedDaily)

        return try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    }

    private static func decode(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func daily(_ obj: [String: Any]) -> [[String: Any]] {
        obj["daily"] as? [[String: Any]] ?? []
    }

    private static func num(_ v: Any?) -> Double {
        (v as? NSNumber)?.doubleValue ?? 0
    }

    private static func intOf(_ v: Any?) -> Int {
        (v as? NSNumber)?.intValue ?? 0
    }

    private static func strings(_ v: Any?) -> [String] {
        v as? [String] ?? []
    }

    private static func union(_ a: [String], _ b: [String]) -> [String] {
        var out = a
        for s in b where !out.contains(s) { out.append(s) }
        return out
    }

    private static func rows(_ day: [String: Any]) -> [(source: String, row: [String: Any])] {
        guard let by = day["bySource"] as? [String: Any] else { return [] }
        return by.flatMap { src, v in
            (v as? [[String: Any]] ?? []).map { (src, $0) }
        }
    }

    private static func rowTokens(_ r: [String: Any]) -> Double {
        num(r["inputTokens"]) + num(r["outputTokens"]) + num(r["cacheCreationTokens"])
            + num(r["cacheReadTokens"])
    }

    public static func dayTokens(_ day: [String: Any]) -> Double {
        rows(day).reduce(0) { $0 + rowTokens($1.row) }
    }

    private static func mergeSessions(_ a: Any?, _ b: Any?) -> [[String: Any]] {
        var seen: [String: [String: Any]] = [:]
        var order: [String] = []
        for list in [b as? [[String: Any]] ?? [], a as? [[String: Any]] ?? []] {
            for s in list {
                guard let id = s["id"] as? String, !id.isEmpty else { continue }
                let key = "\(id)|\(s["source"] as? String ?? "")"
                if let cur = seen[key], cur.count >= s.count { continue }
                if seen[key] == nil { order.append(key) }
                seen[key] = s
            }
        }
        return order.compactMap { seen[$0] }
    }

    private static func totals(of days: [[String: Any]]) -> [String: Any] {
        var input = 0.0
        var output = 0.0
        var cacheCreate = 0.0
        var cacheRead = 0.0
        var cost = 0.0
        var bySource: [String: [String: Double]] = [:]
        for day in days {
            for (src, r) in rows(day) {
                input += num(r["inputTokens"])
                output += num(r["outputTokens"])
                cacheCreate += num(r["cacheCreationTokens"])
                cacheRead += num(r["cacheReadTokens"])
                cost += num(r["cost"])
                var s = bySource[src] ?? ["cost": 0, "tokens": 0]
                s["cost", default: 0] += num(r["cost"])
                s["tokens", default: 0] += rowTokens(r)
                bySource[src] = s
            }
        }
        return [
            "cost": cost,
            "tokens": input + output + cacheCreate + cacheRead,
            "inputTokens": input,
            "outputTokens": output,
            "cacheCreationTokens": cacheCreate,
            "cacheReadTokens": cacheRead,
            "bySource": bySource,
        ]
    }
}
