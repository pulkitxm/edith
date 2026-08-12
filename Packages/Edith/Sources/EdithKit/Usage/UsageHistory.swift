import Foundation

public enum UsageHistory {
    public static func merge(local: Data?, cloud: Data?) -> Data? {
        let rawLocal = local.flatMap(decode)
        let rawCloud = cloud.flatMap(decode)
        let normalizedLocal = rawLocal.map(normalized)
        let normalizedCloud = rawCloud.map(normalized)
        guard let l = normalizedLocal else {
            guard let c = normalizedCloud else { return nil }
            return oneSided(
                original: cloud, raw: rawCloud, normalized: pruningUnusedMachineSources(c))
        }
        guard let cloudDocument = normalizedCloud else {
            return oneSided(
                original: local, raw: rawLocal, normalized: pruningUnusedMachineSources(l))
        }
        let c = removingReplacedMachines(from: cloudDocument, active: l)

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

        return encoded(pruningUnusedMachineSources(out))
    }

    private static let legacyCloudSource = "cc-cloud"

    private struct MachineHistory {
        var host = ""
        var sessionsByTool: [String: Set<String>] = [:]

        var sessionCount: Int {
            sessionsByTool.values.reduce(0) { $0 + $1.count }
        }
    }

    private static func removingReplacedMachines(
        from cloud: [String: Any], active local: [String: Any]
    ) -> [String: Any] {
        let activeIDs = Set(
            (local["machines"] as? [[String: Any]] ?? []).compactMap {
                ($0["id"] as? String)?.lowercased()
            })
        guard !activeIDs.isEmpty else { return cloud }
        let localHistory = machineHistory(local)
        let cloudHistory = machineHistory(cloud)
        let replaced = Set(
            cloudHistory.keys.filter { cloudID in
                guard !activeIDs.contains(cloudID), let old = cloudHistory[cloudID] else {
                    return false
                }
                return activeIDs.contains { activeID in
                    guard activeID != cloudID, let current = localHistory[activeID] else {
                        return false
                    }
                    let sharedTools = Set(old.sessionsByTool.keys).intersection(
                        current.sessionsByTool.keys)
                    let overlap = sharedTools.reduce(0) { total, tool in
                        total
                            + (old.sessionsByTool[tool] ?? []).intersection(
                                current.sessionsByTool[tool] ?? []
                            ).count
                    }
                    let smallerHistory = min(old.sessionCount, current.sessionCount)
                    if !old.host.isEmpty, old.host == current.host, smallerHistory == 1 {
                        return overlap == 1
                    }
                    return overlap >= 2 && overlap * 10 >= smallerHistory * 9
                }
            })
        guard !replaced.isEmpty else { return cloud }
        return removingMachineIDs(replaced, from: cloud)
    }

    private static func machineHistory(_ obj: [String: Any]) -> [String: MachineHistory] {
        let sourceMeta = obj["sourceMeta"] as? [String: Any] ?? [:]
        var history: [String: MachineHistory] = [:]
        for machine in obj["machines"] as? [[String: Any]] ?? [] {
            guard let id = (machine["id"] as? String)?.lowercased() else { continue }
            var item = history[id] ?? MachineHistory()
            item.host = normalizedHost(machine["host"] as? String)
            history[id] = item
        }
        for (source, value) in sourceMeta {
            guard let id = machineIdentity(source, sourceMeta: sourceMeta)?.id else { continue }
            let meta = value as? [String: Any]
            let host = normalizedHost(meta?["machineHost"] as? String)
            var item = history[id] ?? MachineHistory()
            if !host.isEmpty { item.host = host }
            history[id] = item
        }
        for session in obj["sessions"] as? [[String: Any]] ?? [] {
            guard let source = session["source"] as? String,
                let id = session["id"] as? String, !id.isEmpty,
                let identity = machineIdentity(source, sourceMeta: sourceMeta)
            else { continue }
            var item = history[identity.id] ?? MachineHistory()
            item.sessionsByTool[identity.tool, default: []].insert(id)
            history[identity.id] = item
        }
        return history
    }

    private static func normalizedHost(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private static func machineIdentity(
        _ source: String, sourceMeta: [String: Any]
    ) -> (id: String, tool: String)? {
        let pieces = source.split(separator: ":", omittingEmptySubsequences: false)
        let tool = pieces.last.map(String.init)?.lowercased() ?? ""
        let metadataID = ((sourceMeta[source] as? [String: Any])?["machineID"] as? String)?
            .lowercased()
        let canonicalID =
            pieces.count >= 3 && pieces[0].lowercased() == "machine"
            ? String(pieces[1]).lowercased() : nil
        guard let id = metadataID ?? canonicalID, !id.isEmpty, !tool.isEmpty else { return nil }
        return (id, tool)
    }

    private static func removingMachineIDs(
        _ ids: Set<String>, from obj: [String: Any]
    ) -> [String: Any] {
        let sourceMeta = obj["sourceMeta"] as? [String: Any] ?? [:]
        let keep: (String) -> Bool = { source in
            guard let id = machineIdentity(source, sourceMeta: sourceMeta)?.id else { return true }
            return !ids.contains(id)
        }
        var out = obj
        out["sources"] = strings(obj["sources"]).filter(keep)
        out["defaultSources"] = strings(obj["defaultSources"]).filter(keep)
        out["sourceMeta"] = sourceMeta.filter { keep($0.key) }
        out["machines"] = (obj["machines"] as? [[String: Any]] ?? []).filter {
            guard let id = ($0["id"] as? String)?.lowercased() else { return true }
            return !ids.contains(id)
        }
        out["sessions"] = (obj["sessions"] as? [[String: Any]] ?? []).filter {
            guard let source = $0["source"] as? String else { return true }
            return keep(source)
        }
        let filteredDaily = daily(obj).map {
            filteringMachineDay($0, keep: keep)
        }
        out["daily"] = filteredDaily
        out["totals"] = totals(of: filteredDaily)
        return out
    }

    private static func filteringMachineDay(
        _ day: [String: Any], keep: (String) -> Bool
    ) -> [String: Any] {
        var out = day
        out["bySource"] = filteringSourceMap(day["bySource"], keep: keep)
        if let hours = day["hours"] as? [[String: Any]] {
            out["hours"] = hours.map {
                filteringMachineDetail($0, keepEmpty: true, keep: keep) ?? [:]
            }
        }
        if let projects = day["projects"] as? [[String: Any]] {
            out["projects"] = projects.compactMap {
                filteringMachineProject($0, keep: keep)
            }
        }
        return out
    }

    private static func filteringMachineDetail(
        _ detail: [String: Any], keepEmpty: Bool, keep: (String) -> Bool
    ) -> [String: Any]? {
        var out = detail
        if detail["bySource"] != nil {
            let bySource = filteringSourceMap(detail["bySource"], keep: keep)
            guard keepEmpty || !bySource.isEmpty else { return nil }
            out["bySource"] = bySource
            setDetailTotals(&out, bySource: bySource)
        }
        if let paths = detail["byPath"] as? [String: Any] {
            out["byPath"] = paths.reduce(into: [String: Any]()) { result, entry in
                guard let value = entry.value as? [String: Any],
                    let filtered = filteringMachineDetail(value, keepEmpty: false, keep: keep)
                else { return }
                result[entry.key] = filtered
            }
        }
        return out
    }

    private static func filteringMachineProject(
        _ project: [String: Any], keep: (String) -> Bool
    ) -> [String: Any]? {
        guard var out = filteringMachineDetail(project, keepEmpty: false, keep: keep) else {
            return nil
        }
        if let chats = project["chats"] as? [[String: Any]] {
            out["chats"] = chats.filter { recordUsesKeptSource($0, keep: keep) }
        }
        if let worktrees = project["worktrees"] as? [[String: Any]] {
            out["worktrees"] = worktrees.compactMap {
                filteringMachineWorktree($0, keep: keep)
            }
        }
        return out
    }

    private static func filteringMachineWorktree(
        _ worktree: [String: Any], keep: (String) -> Bool
    ) -> [String: Any]? {
        guard var out = filteringMachineDetail(worktree, keepEmpty: false, keep: keep) else {
            return nil
        }
        guard let chats = worktree["chats"] as? [[String: Any]] else { return out }
        let filtered = chats.filter { recordUsesKeptSource($0, keep: keep) }
        guard !filtered.isEmpty || chats.isEmpty else { return nil }
        out["chats"] = filtered
        if worktree["bySource"] == nil {
            out["tokens"] = filtered.reduce(0) { $0 + num($1["tokens"]) }
            out["cost"] = filtered.reduce(0) { $0 + num($1["cost"]) }
        }
        return out
    }

    private static func filteringSourceMap(
        _ value: Any?, keep: (String) -> Bool
    ) -> [String: Any] {
        (value as? [String: Any] ?? [:]).filter { keep($0.key) }
    }

    private static func recordUsesKeptSource(
        _ record: [String: Any], keep: (String) -> Bool
    ) -> Bool {
        guard let source = record["source"] as? String else { return true }
        return keep(source)
    }

    private static func normalized(_ decoded: [String: Any]) -> [String: Any] {
        return removingUnsafeCodexDetail(
            canonicalizedMachineSources(foldLegacyCloudSource(decoded)))
    }

    private static func pruningUnusedMachineSources(_ obj: [String: Any]) -> [String: Any] {
        let active = Set(
            daily(obj).flatMap { day in
                (day["bySource"] as? [String: Any] ?? [:]).keys
            })
        let sourceMeta = obj["sourceMeta"] as? [String: Any] ?? [:]
        let unusedMachines = Set(
            sourceMeta.compactMap { source, value -> String? in
                guard let meta = value as? [String: Any], meta["machineID"] is String,
                    !active.contains(source)
                else { return nil }
                return source
            })
        var out = obj
        out["sources"] = strings(obj["sources"]).filter { !unusedMachines.contains($0) }
        out["defaultSources"] = strings(obj["defaultSources"]).filter {
            !unusedMachines.contains($0)
        }
        out["sourceMeta"] = sourceMeta.filter { !unusedMachines.contains($0.key) }
        return out
    }

    private static func oneSided(
        original: Data?, raw: [String: Any]?, normalized: [String: Any]
    ) -> Data? {
        guard let original, let raw, encoded(raw) == encoded(normalized) else {
            return encoded(normalized)
        }
        return original
    }

    private static func encoded(_ value: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

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

    static func canonicalizedMachineSources(_ obj: [String: Any]) -> [String: Any] {
        let sourceMeta = obj["sourceMeta"] as? [String: Any] ?? [:]
        let aliases = machineSourceAliases(sourceMeta)
        guard !aliases.isEmpty else { return obj }
        let preferred = preferredMachineSources(in: obj, sourceMeta: sourceMeta, aliases: aliases)
        var out = obj
        out["sources"] = canonicalizedSourceList(strings(obj["sources"]), aliases: aliases)
        out["defaultSources"] = canonicalizedSourceList(
            strings(obj["defaultSources"]), aliases: aliases)
        out["sourceMeta"] = canonicalizedSourceMeta(
            sourceMeta, aliases: aliases, preferred: preferred)
        if let sessions = obj["sessions"] as? [[String: Any]] {
            out["sessions"] = canonicalizedSessions(
                sessions, aliases: aliases, preferred: preferred)
        }
        let normalizedDaily = daily(obj).map {
            canonicalizedMachineDay($0, aliases: aliases, preferred: preferred)
        }
        out["daily"] = normalizedDaily
        out["totals"] = totals(of: normalizedDaily)
        return out
    }

    private static func machineSourceAliases(_ sourceMeta: [String: Any]) -> [String: String] {
        sourceMeta.reduce(into: [:]) { aliases, entry in
            guard let meta = entry.value as? [String: Any],
                let machineID = meta["machineID"] as? String,
                let canonical = MachineUsageSourceIdentity.canonical(
                    machineID: machineID, source: entry.key)
            else { return }
            aliases[entry.key] = canonical
        }
    }

    private static func scopedPreferredSources(
        _ value: Any?, aliases: [String: String], preferred: [String: String]
    ) -> [String: String] {
        guard let sourceMap = value as? [String: Any] else { return [:] }
        let grouped = Dictionary(grouping: sourceMap.keys, by: { aliases[$0] ?? $0 })
        return grouped.reduce(into: [:]) { result, entry in
            let canonical = entry.key
            let candidates = entry.value.sorted()
            if candidates.contains(canonical) {
                result[canonical] = canonical
            } else if let selected = preferred[canonical], candidates.contains(selected) {
                result[canonical] = selected
            } else {
                result[canonical] = candidates.first
            }
        }
    }

    private static func preferredMachineSources(
        in obj: [String: Any], sourceMeta: [String: Any], aliases: [String: String]
    ) -> [String: String] {
        let machineSlugs = (obj["machines"] as? [[String: Any]] ?? []).reduce(
            into: [String: String]()
        ) { slugs, machine in
            guard let id = machine["id"] as? String,
                let slug = machine["slug"] as? String
            else { return }
            slugs[id.lowercased()] = slug.lowercased()
        }
        let grouped = Dictionary(grouping: aliases.keys, by: { aliases[$0] ?? $0 })
        return grouped.reduce(into: [:]) { result, entry in
            let canonical = entry.key
            let candidates = entry.value.sorted()
            if candidates.contains(canonical) {
                result[canonical] = canonical
                return
            }
            let machineID = candidates.compactMap {
                (sourceMeta[$0] as? [String: Any])?["machineID"] as? String
            }.first?.lowercased()
            if let machineID, let slug = machineSlugs[machineID],
                let current = candidates.first(where: { source in
                    source.lowercased().hasPrefix("\(slug):")
                })
            {
                result[canonical] = current
            } else {
                result[canonical] = candidates.first
            }
        }
    }

    private static func canonicalizedSourceList(
        _ sources: [String], aliases: [String: String]
    ) -> [String] {
        var seen = Set<String>()
        return sources.compactMap { source in
            let canonical = aliases[source] ?? source
            return seen.insert(canonical).inserted ? canonical : nil
        }
    }

    private static func canonicalizedSourceMeta(
        _ sourceMeta: [String: Any], aliases: [String: String], preferred: [String: String]
    ) -> [String: Any] {
        sourceMeta.keys.sorted().reduce(into: [:]) { meta, source in
            let canonical = aliases[source] ?? source
            if preferred[canonical] == nil || preferred[canonical] == source {
                meta[canonical] = sourceMeta[source]
            }
        }
    }

    private static func canonicalizedSourceMap(
        _ value: Any?, aliases: [String: String], preferred: [String: String]
    ) -> [String: Any]? {
        guard let sourceMap = value as? [String: Any] else { return nil }
        return sourceMap.keys.sorted().reduce(into: [:]) { result, source in
            let canonical = aliases[source] ?? source
            if preferred[canonical] == nil || preferred[canonical] == source {
                result[canonical] = sourceMap[source]
            }
        }
    }

    private static func canonicalizedSessions(
        _ sessions: [[String: Any]], aliases: [String: String], preferred: [String: String]
    ) -> [[String: Any]] {
        var order: [String] = []
        var records: [String: [String: Any]] = [:]
        var priorities: [String: Int] = [:]
        for (index, session) in sessions.enumerated() {
            guard let source = session["source"] as? String else {
                let key = "unqualified:\(index)"
                order.append(key)
                records[key] = session
                continue
            }
            let canonical = aliases[source] ?? source
            var normalized = session
            normalized["source"] = canonical
            let id = session["id"] as? String ?? ""
            let key = id.isEmpty ? "unidentified:\(index)" : "\(canonical)\u{1F}\(id)"
            let priority =
                source == canonical ? 2 : (preferred[canonical] == source ? 1 : 0)
            if records[key] == nil {
                order.append(key)
                records[key] = normalized
                priorities[key] = priority
            } else if priority > (priorities[key] ?? -1)
                || (priority == priorities[key] && normalized.count >= (records[key]?.count ?? 0))
            {
                records[key] = normalized
                priorities[key] = priority
            }
        }
        return order.compactMap { records[$0] }
    }

    private static func canonicalizedSourceRecord(
        _ record: [String: Any], aliases: [String: String], preferred: [String: String]
    ) -> [String: Any]? {
        guard let source = record["source"] as? String else { return record }
        let canonical = aliases[source] ?? source
        guard preferred[canonical] == nil || preferred[canonical] == source else {
            return nil
        }
        guard canonical != source else { return record }
        var out = record
        out["source"] = canonical
        return out
    }

    private static func canonicalizedMachineDay(
        _ day: [String: Any], aliases: [String: String], preferred: [String: String]
    ) -> [String: Any] {
        var out = day
        let scopedPreferred = scopedPreferredSources(
            day["bySource"], aliases: aliases, preferred: preferred)
        if let bySource = canonicalizedSourceMap(
            day["bySource"], aliases: aliases, preferred: scopedPreferred)
        {
            out["bySource"] = bySource
        }
        if let hours = day["hours"] as? [[String: Any]] {
            out["hours"] = hours.map {
                canonicalizedHour($0, aliases: aliases, preferred: scopedPreferred)
            }
        }
        if let projects = day["projects"] as? [[String: Any]] {
            out["projects"] = projects.compactMap {
                canonicalizedMachineProject($0, aliases: aliases, preferred: scopedPreferred)
            }
        }
        return out
    }

    private static func canonicalizedHour(
        _ hour: [String: Any], aliases: [String: String], preferred: [String: String]
    ) -> [String: Any] {
        var out = hour
        if let bySource = canonicalizedSourceMap(
            hour["bySource"], aliases: aliases, preferred: preferred)
        {
            out["bySource"] = bySource
            setDetailTotals(&out, bySource: bySource)
        }
        if let paths = hour["byPath"] as? [String: Any] {
            out["byPath"] = paths.reduce(into: [String: Any]()) { result, entry in
                guard var path = entry.value as? [String: Any] else {
                    result[entry.key] = entry.value
                    return
                }
                if let bySource = canonicalizedSourceMap(
                    path["bySource"], aliases: aliases, preferred: preferred)
                {
                    guard !bySource.isEmpty else { return }
                    path["bySource"] = bySource
                    setDetailTotals(&path, bySource: bySource)
                }
                result[entry.key] = path
            }
        }
        return out
    }

    private static func canonicalizedMachineProject(
        _ project: [String: Any], aliases: [String: String], preferred: [String: String]
    ) -> [String: Any]? {
        var out = project
        let originalChats = project["chats"] as? [[String: Any]] ?? []
        let originalWorktrees = project["worktrees"] as? [[String: Any]] ?? []
        if let bySource = canonicalizedSourceMap(
            project["bySource"], aliases: aliases, preferred: preferred)
        {
            guard !bySource.isEmpty else { return nil }
            out["bySource"] = bySource
            setDetailTotals(&out, bySource: bySource)
        }
        let chats = originalChats.compactMap {
            canonicalizedSourceRecord($0, aliases: aliases, preferred: preferred)
        }
        if project["chats"] != nil {
            out["chats"] = chats
        }
        let worktrees = originalWorktrees.compactMap {
            canonicalizedMachineWorktree($0, aliases: aliases, preferred: preferred)
        }
        if project["worktrees"] != nil {
            out["worktrees"] = worktrees
        }
        if project["bySource"] == nil && (!originalChats.isEmpty || !originalWorktrees.isEmpty) {
            guard !chats.isEmpty || !worktrees.isEmpty else { return nil }
            out["tokens"] =
                chats.reduce(0) { $0 + num($1["tokens"]) }
                + worktrees.reduce(0) { $0 + num($1["tokens"]) }
            out["cost"] =
                chats.reduce(0) { $0 + num($1["cost"]) }
                + worktrees.reduce(0) { $0 + num($1["cost"]) }
        }
        return out
    }

    private static func canonicalizedMachineWorktree(
        _ worktree: [String: Any], aliases: [String: String], preferred: [String: String]
    ) -> [String: Any]? {
        var out = worktree
        if let bySource = canonicalizedSourceMap(
            worktree["bySource"], aliases: aliases, preferred: preferred)
        {
            guard !bySource.isEmpty else { return nil }
            out["bySource"] = bySource
            setDetailTotals(&out, bySource: bySource)
        }
        if let chats = worktree["chats"] as? [[String: Any]] {
            let retained = chats.compactMap {
                canonicalizedSourceRecord($0, aliases: aliases, preferred: preferred)
            }
            guard !retained.isEmpty || chats.isEmpty else { return nil }
            out["chats"] = retained
            if worktree["bySource"] == nil {
                out["tokens"] = retained.reduce(0) { $0 + num($1["tokens"]) }
                out["cost"] = retained.reduce(0) { $0 + num($1["cost"]) }
            }
        }
        return out
    }

    private static func removingUnsafeCodexDetail(_ obj: [String: Any]) -> [String: Any] {
        var out = obj
        let originalDays = daily(obj)
        let normalizedDays = originalDays.map(removingUnsafeCodexDay)
        guard serialized(originalDays) != serialized(normalizedDays) else { return obj }
        out["daily"] = normalizedDays
        out["totals"] = totals(of: normalizedDays)
        return out
    }

    private static func serialized(_ value: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private static func removingUnsafeCodexDay(_ day: [String: Any]) -> [String: Any] {
        var out = day
        let canonicalSources = day["bySource"] as? [String: Any] ?? [:]
        let hasCodex = canonicalSources.keys.contains(where: isCodexSource)
        if let hours = day["hours"] as? [[String: Any]] {
            out["hours"] = hours.map {
                removingUnsafeCodexDetail($0, canonicalDayHasCodex: hasCodex)
            }
        }
        if let projects = day["projects"] as? [[String: Any]] {
            out["projects"] = projects.compactMap(removingUnsafeCodexProject)
        }
        return out
    }

    private static func removingUnsafeCodexDetail(
        _ hour: [String: Any], canonicalDayHasCodex: Bool
    ) -> [String: Any] {
        var out = hour
        if let bySource = withoutCodexSources(hour["bySource"]) {
            out["bySource"] = bySource
            setDetailTotals(&out, bySource: bySource)
            out["byPath"] = withoutCodexPaths(hour["byPath"])
        } else if canonicalDayHasCodex {
            out["tokens"] = 0.0
            out["cost"] = 0.0
            out["bySource"] = [String: Any]()
            out["byPath"] = [String: Any]()
        }
        return out
    }

    private static func withoutCodexPaths(_ value: Any?) -> [String: Any] {
        let paths = value as? [String: Any] ?? [:]
        return paths.reduce(into: [:]) { result, entry in
            guard var path = entry.value as? [String: Any],
                let bySource = withoutCodexSources(path["bySource"]), !bySource.isEmpty
            else { return }
            path["bySource"] = bySource
            setDetailTotals(&path, bySource: bySource)
            result[entry.key] = path
        }
    }

    private static func removingUnsafeCodexProject(
        _ project: [String: Any]
    ) -> [String: Any]? {
        var out = project
        let originalBySource = project["bySource"] as? [String: Any]
        let bySource = withoutCodexSources(project["bySource"])
        let originalChats = project["chats"] as? [[String: Any]] ?? []
        let chats = originalChats.filter { !isCodexSource($0["source"] as? String ?? "") }
        let originalWorktrees = project["worktrees"] as? [[String: Any]] ?? []
        let worktrees = originalWorktrees.compactMap(removingUnsafeCodexWorktree)
        out["chats"] = chats
        out["worktrees"] = worktrees
        if let bySource {
            guard !bySource.isEmpty else { return nil }
            out["bySource"] = bySource
            setDetailTotals(&out, bySource: bySource)
        } else if !originalChats.isEmpty || !originalWorktrees.isEmpty {
            guard !chats.isEmpty || !worktrees.isEmpty else { return nil }
            out["tokens"] =
                chats.reduce(0) { $0 + num($1["tokens"]) }
                + worktrees.reduce(0) { $0 + num($1["tokens"]) }
            out["cost"] =
                chats.reduce(0) { $0 + num($1["cost"]) }
                + worktrees.reduce(0) { $0 + num($1["cost"]) }
        } else if originalBySource != nil {
            return nil
        }
        return out
    }

    private static func removingUnsafeCodexWorktree(
        _ worktree: [String: Any]
    ) -> [String: Any]? {
        var out = worktree
        let originalBySource = worktree["bySource"] as? [String: Any]
        let bySource = withoutCodexSources(worktree["bySource"])
        let originalChats = worktree["chats"] as? [[String: Any]] ?? []
        let chats = originalChats.filter { !isCodexSource($0["source"] as? String ?? "") }
        out["chats"] = chats
        if let bySource {
            guard !bySource.isEmpty else { return nil }
            out["bySource"] = bySource
            setDetailTotals(&out, bySource: bySource)
        } else if !originalChats.isEmpty {
            guard !chats.isEmpty else { return nil }
            out["tokens"] = chats.reduce(0) { $0 + num($1["tokens"]) }
            out["cost"] = chats.reduce(0) { $0 + num($1["cost"]) }
        } else if originalBySource != nil {
            return nil
        }
        return out
    }

    private static func withoutCodexSources(_ value: Any?) -> [String: Any]? {
        guard let sources = value as? [String: Any] else { return nil }
        return sources.filter { !isCodexSource($0.key) }
    }

    private static func isCodexSource(_ source: String) -> Bool {
        source.split(separator: ":", omittingEmptySubsequences: false).last?
            .lowercased() == "codex"
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
