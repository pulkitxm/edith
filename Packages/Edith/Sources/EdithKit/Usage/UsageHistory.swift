import Foundation

public enum UsageHistory {
    public static func merge(local: Data?, cloud: Data?) -> Data? {
        guard let local else { return cloud }
        guard let cloud else { return local }
        guard let rawLocal = decode(local) else { return cloud }
        guard let rawCloud = decode(cloud) else { return local }
        let l = foldLegacyCloudSource(rawLocal)
        let c = foldLegacyCloudSource(rawCloud)
        let preferLocalDays = intOf(l["schemaVersion"]) > intOf(c["schemaVersion"])

        var best: [String: [String: Any]] = [:]
        for day in daily(c) {
            guard let p = day["period"] as? String else { continue }
            best[p] = day
        }
        for day in daily(l) {
            guard let p = day["period"] as? String else { continue }
            if !preferLocalDays, let cur = best[p], dayTokens(cur) > dayTokens(day) { continue }
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

    private static let legacyCloudSource = "cc-cloud"

    static func foldLegacyCloudSource(_ obj: [String: Any]) -> [String: Any] {
        var out = obj
        out["sources"] = foldedSourceList(strings(obj["sources"]))
        out["defaultSources"] = foldedSourceList(strings(obj["defaultSources"]))
        if var meta = obj["sourceMeta"] as? [String: Any], meta[legacyCloudSource] != nil {
            meta[legacyCloudSource] = nil
            out["sourceMeta"] = meta
        }
        if let sessions = obj["sessions"] as? [[String: Any]] {
            out["sessions"] = sessions.map(relabeledSession)
        }
        out["daily"] = daily(obj).map(foldedDay)
        return out
    }

    private static func foldedSourceList(_ sources: [String]) -> [String] {
        guard sources.contains(legacyCloudSource) else { return sources }
        var kept = sources.filter { $0 != legacyCloudSource }
        if !kept.contains("cli") { kept.append("cli") }
        return kept
    }

    private static func relabeledSession(_ session: [String: Any]) -> [String: Any] {
        guard session["source"] as? String == legacyCloudSource else { return session }
        var out = session
        out["source"] = "cli"
        return out
    }

    private static func foldedDay(_ day: [String: Any]) -> [String: Any] {
        var out = day
        if var by = day["bySource"] as? [String: Any],
            let legacyRows = by[legacyCloudSource] as? [[String: Any]]
        {
            var rows = by["cli"] as? [[String: Any]] ?? []
            for row in legacyRows {
                let name = row["modelName"] as? String ?? "unknown"
                if let i = rows.firstIndex(where: {
                    ($0["modelName"] as? String ?? "unknown") == name
                }) {
                    rows[i] = combinedRow(rows[i], row)
                } else {
                    rows.append(row)
                }
            }
            by["cli"] = rows
            by[legacyCloudSource] = nil
            out["bySource"] = by
        }
        if let projects = day["projects"] as? [[String: Any]] {
            out["projects"] = projects.map(relabeledProject)
        }
        return out
    }

    private static func combinedRow(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
        var out = a
        let numericKeys = [
            "inputTokens", "outputTokens", "cacheCreationTokens", "cacheReadTokens", "cost",
        ]
        for key in numericKeys {
            out[key] = num(a[key]) + num(b[key])
        }
        return out
    }

    private static func relabeledProject(_ project: [String: Any]) -> [String: Any] {
        var out = project
        if let chats = project["chats"] as? [[String: Any]] {
            out["chats"] = chats.map(relabeledChat)
        }
        if let worktrees = project["worktrees"] as? [[String: Any]] {
            out["worktrees"] = worktrees.map { wt -> [String: Any] in
                var next = wt
                if let chats = wt["chats"] as? [[String: Any]] {
                    next["chats"] = chats.map(relabeledChat)
                }
                return next
            }
        }
        return out
    }

    private static func relabeledChat(_ chat: [String: Any]) -> [String: Any] {
        guard chat["source"] as? String == legacyCloudSource else { return chat }
        var out = chat
        out["source"] = "cli"
        return out
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
