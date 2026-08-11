import Foundation

public enum UsageHistory {
    public static func merge(local: Data?, cloud: Data?) -> Data? {
        guard let local else { return cloud }
        guard let cloud else { return local }
        guard let rawLocal = decode(local) else { return cloud }
        guard let rawCloud = decode(cloud) else { return local }
        let l = foldLegacyCloudSource(rawLocal)
        let c = foldLegacyCloudSource(rawCloud)

        var mergedByPeriod: [String: [String: Any]] = [:]
        for day in daily(c) {
            guard let p = day["period"] as? String else { continue }
            mergedByPeriod[p] = day
        }
        for day in daily(l) {
            guard let p = day["period"] as? String else { continue }
            if let cloudDay = mergedByPeriod[p] {
                mergedByPeriod[p] = mergeDay(
                    local: day, cloud: cloudDay,
                    mergeSourceDetail: intOf(l["schemaVersion"]) >= 7
                        && intOf(c["schemaVersion"]) >= 7)
            } else {
                mergedByPeriod[p] = day
            }
        }
        let mergedDaily = mergedByPeriod.keys.sorted().compactMap { mergedByPeriod[$0] }

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

    private static func mergeDay(
        local: [String: Any], cloud: [String: Any], mergeSourceDetail: Bool
    ) -> [String: Any] {
        var out = cloud
        for (key, value) in local { out[key] = value }
        var bySource = cloud["bySource"] as? [String: Any] ?? [:]
        let localBySource = local["bySource"] as? [String: Any] ?? [:]
        for (source, value) in localBySource {
            bySource[source] = value
        }
        out["bySource"] = bySource
        guard mergeSourceDetail else { return out }
        let replacingSources = Set(localBySource.keys)
        out["hours"] = mergeHours(
            local["hours"], cloud["hours"], replacingSources: replacingSources)
        out["projects"] = mergeProjects(
            local["projects"], cloud["projects"], replacingSources: replacingSources)
        return out
    }

    private static func mergeHours(
        _ localValue: Any?, _ cloudValue: Any?, replacingSources: Set<String>
    ) -> [[String: Any]] {
        let local = localValue as? [[String: Any]] ?? []
        let cloud = cloudValue as? [[String: Any]] ?? []
        guard hasSourceDetail(local), hasSourceDetail(cloud) else {
            return localValue != nil ? local : cloud
        }
        return (0..<max(local.count, cloud.count)).map { index in
            let localHour = index < local.count ? local[index] : [:]
            let cloudHour = index < cloud.count ? cloud[index] : [:]
            var merged = cloudHour
            for (key, value) in localHour { merged[key] = value }
            let bySource = mergedSourceMap(
                localHour["bySource"], cloudHour["bySource"],
                replacingSources: replacingSources)
            merged["bySource"] = bySource
            merged["byPath"] = mergedPathMap(
                localHour["byPath"], cloudHour["byPath"],
                replacingSources: replacingSources)
            setDetailTotals(&merged, bySource: bySource)
            return merged
        }
    }

    private static func mergeProjects(
        _ localValue: Any?, _ cloudValue: Any?, replacingSources: Set<String>
    ) -> [[String: Any]] {
        let local = localValue as? [[String: Any]] ?? []
        let cloud = cloudValue as? [[String: Any]] ?? []
        guard hasSourceDetail(local), hasSourceDetail(cloud) else {
            return localValue != nil ? local : cloud
        }
        var localByKey: [String: [String: Any]] = [:]
        var cloudByKey: [String: [String: Any]] = [:]
        var order: [String] = []
        for project in cloud {
            let key = projectKey(project)
            if cloudByKey[key] == nil { order.append(key) }
            cloudByKey[key] = project
        }
        for project in local {
            let key = projectKey(project)
            if localByKey[key] == nil, cloudByKey[key] == nil { order.append(key) }
            localByKey[key] = project
        }
        return order.compactMap { key in
            let localProject = localByKey[key] ?? [:]
            let cloudProject = cloudByKey[key] ?? [:]
            var merged = cloudProject
            for (field, value) in localProject { merged[field] = value }
            let bySource = mergedSourceMap(
                localProject["bySource"], cloudProject["bySource"],
                replacingSources: replacingSources)
            guard !bySource.isEmpty else { return nil }
            merged["bySource"] = bySource
            merged["chats"] = mergeChats(
                localProject["chats"], cloudProject["chats"],
                replacingSources: replacingSources)
            merged["worktrees"] = mergeWorktrees(
                localProject["worktrees"], cloudProject["worktrees"],
                replacingSources: replacingSources)
            setDetailTotals(&merged, bySource: bySource)
            return merged
        }
    }

    private static func mergeChats(
        _ localValue: Any?, _ cloudValue: Any?, replacingSources: Set<String>
    ) -> [[String: Any]] {
        let local = localValue as? [[String: Any]] ?? []
        let cloud = cloudValue as? [[String: Any]] ?? []
        var merged: [String: [String: Any]] = [:]
        var order: [String] = []
        for chat in cloud {
            let source = chat["source"] as? String ?? ""
            guard !replacingSources.contains(source) else { continue }
            let key = chatKey(chat)
            if merged[key] == nil { order.append(key) }
            merged[key] = chat
        }
        for chat in local {
            let key = chatKey(chat)
            if merged[key] == nil { order.append(key) }
            merged[key] = chat
        }
        return order.compactMap { merged[$0] }
    }

    private static func mergeWorktrees(
        _ localValue: Any?, _ cloudValue: Any?, replacingSources: Set<String>
    ) -> [[String: Any]] {
        let local = localValue as? [[String: Any]] ?? []
        let cloud = cloudValue as? [[String: Any]] ?? []
        var localByKey: [String: [String: Any]] = [:]
        var cloudByKey: [String: [String: Any]] = [:]
        var order: [String] = []
        for worktree in cloud {
            let key = worktreeKey(worktree)
            if cloudByKey[key] == nil { order.append(key) }
            cloudByKey[key] = worktree
        }
        for worktree in local {
            let key = worktreeKey(worktree)
            if localByKey[key] == nil, cloudByKey[key] == nil { order.append(key) }
            localByKey[key] = worktree
        }
        return order.compactMap { key in
            let localWorktree = localByKey[key] ?? [:]
            let cloudWorktree = cloudByKey[key] ?? [:]
            var merged = cloudWorktree
            for (field, value) in localWorktree { merged[field] = value }
            let chats = mergeChats(
                localWorktree["chats"], cloudWorktree["chats"],
                replacingSources: replacingSources)
            guard !chats.isEmpty || !localWorktree.isEmpty else { return nil }
            merged["chats"] = chats
            merged["tokens"] = chats.reduce(0) { $0 + num($1["tokens"]) }
            merged["cost"] = chats.reduce(0) { $0 + num($1["cost"]) }
            return merged
        }
    }

    private static func chatKey(_ chat: [String: Any]) -> String {
        let source = chat["source"] as? String ?? ""
        let id = chat["id"] as? String ?? ""
        let identity =
            id.isEmpty
            ? [chat["path"] as? String ?? "", chat["title"] as? String ?? ""]
                .joined(separator: "\u{1F}") : id
        return [source, identity].joined(separator: "\u{1F}")
    }

    private static func worktreeKey(_ worktree: [String: Any]) -> String {
        [worktree["name"] as? String ?? "", worktree["path"] as? String ?? ""]
            .joined(separator: "\u{1F}")
    }

    private static func hasSourceDetail(_ rows: [[String: Any]]) -> Bool {
        rows.allSatisfy { $0["bySource"] is [String: Any] }
    }

    private static func mergedSourceMap(
        _ localValue: Any?, _ cloudValue: Any?, replacingSources: Set<String>
    ) -> [String: Any] {
        var merged = cloudValue as? [String: Any] ?? [:]
        for source in replacingSources { merged[source] = nil }
        for (source, value) in localValue as? [String: Any] ?? [:] {
            merged[source] = value
        }
        return merged
    }

    private static func mergedPathMap(
        _ localValue: Any?, _ cloudValue: Any?, replacingSources: Set<String>
    ) -> [String: Any] {
        let local = localValue as? [String: Any] ?? [:]
        let cloud = cloudValue as? [String: Any] ?? [:]
        var keys = Array(cloud.keys)
        for key in local.keys where !keys.contains(key) { keys.append(key) }
        return keys.reduce(into: [String: Any]()) { paths, path in
            let localPath = local[path] as? [String: Any] ?? [:]
            let cloudPath = cloud[path] as? [String: Any] ?? [:]
            var merged = cloudPath
            for (key, value) in localPath { merged[key] = value }
            let bySource = mergedSourceMap(
                localPath["bySource"], cloudPath["bySource"],
                replacingSources: replacingSources)
            guard !bySource.isEmpty else { return }
            merged["bySource"] = bySource
            setDetailTotals(&merged, bySource: bySource)
            paths[path] = merged
        }
    }

    private static func setDetailTotals(
        _ detail: inout [String: Any], bySource: [String: Any]
    ) {
        detail["tokens"] = bySource.values.reduce(0) { $0 + detailTokens($1) }
        detail["cost"] = bySource.values.reduce(0) { $0 + detailCost($1) }
    }

    private static func detailTokens(_ value: Any) -> Double {
        guard let detail = value as? [String: Any] else { return 0 }
        if detail["tokens"] != nil { return num(detail["tokens"]) }
        let models = detail["byModel"] as? [String: Any] ?? [:]
        return models.values.reduce(0) { $0 + detailTokens($1) }
    }

    private static func detailCost(_ value: Any) -> Double {
        guard let detail = value as? [String: Any] else { return 0 }
        if detail["cost"] != nil { return num(detail["cost"]) }
        let models = detail["byModel"] as? [String: Any] ?? [:]
        return models.values.reduce(0) { $0 + detailCost($1) }
    }

    private static func projectKey(_ project: [String: Any]) -> String {
        [
            project["repositoryID"] as? String ?? project["projectName"] as? String ?? "unknown",
            project["machineID"] as? String ?? project["machineName"] as? String ?? "",
            project["path"] as? String ?? project["folderName"] as? String ?? "",
        ].joined(separator: "\u{1F}")
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
                if let cur = seen[key], cur.count > s.count { continue }
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
