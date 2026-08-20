import Foundation

public enum HerdrListParser {
    public static func sessions(from text: String) -> [String] {
        var seen = Set<String>()
        return sessionRecords(from: text).map(\.name).filter { seen.insert($0).inserted }
    }

    public static func sessionRecords(from text: String) -> [HerdrSessionRecord] {
        guard let json = firstJSON(in: text) else { return [] }
        let payload = unwrap(json)
        let values: [Any]
        if let array = payload as? [Any] {
            values = array
        } else if let object = payload as? [String: Any] {
            values =
                array(in: object, keys: ["sessions", "session_list", "names"]) ?? []
        } else {
            values = []
        }
        var records: [HerdrSessionRecord] = []
        var seen = Set<String>()
        for value in values {
            if let name = string(value), seen.insert(name).inserted {
                records.append(HerdrSessionRecord(name: name, running: true, socketPath: nil))
                continue
            }
            guard let object = value as? [String: Any] else { continue }
            guard
                let name = string(in: object, keys: ["name", "session", "id", "session_name"]),
                seen.insert(name).inserted
            else { continue }
            let running =
                object["running"] as? Bool ?? object["alive"] as? Bool
                ?? object["active"] as? Bool ?? true
            records.append(
                HerdrSessionRecord(
                    name: name, running: running,
                    socketPath: string(in: object, keys: ["socket_path", "socket", "path"])))
        }
        return records
    }

    public static func hasSnapshot(_ text: String) -> Bool {
        guard let object = firstJSON(in: text) as? [String: Any] else { return false }
        let payload = unwrap(object) as? [String: Any] ?? object
        if payload["snapshot"] is [String: Any] { return true }
        return string(payload["type"]) == "session_snapshot"
    }

    public static func isEventLine(_ text: String) -> Bool {
        guard let object = firstJSON(in: text) as? [String: Any] else { return false }
        return object["event"] != nil
    }

    public static func snapshotBoard(from text: String) -> HerdrSnapshotBoard? {
        guard hasSnapshot(text) else { return nil }
        guard let json = firstJSON(in: text) as? [String: Any] else { return nil }
        let payload = unwrap(json) as? [String: Any] ?? [:]
        let snapshot = payload["snapshot"] as? [String: Any] ?? payload
        var labels: [String: String] = [:]
        for value in snapshot["workspaces"] as? [Any] ?? [] {
            guard let workspace = value as? [String: Any] else { continue }
            guard let id = string(in: workspace, keys: ["workspace_id", "id"]) else { continue }
            labels[id] = string(in: workspace, keys: ["label", "name"]) ?? id
        }
        let paneValues = snapshot["panes"] as? [Any]
        let agentValues = snapshot["agents"] as? [Any] ?? []
        return HerdrSnapshotBoard(
            labels: labels,
            panes: (paneValues ?? []).compactMap { paneRecord(from: $0) },
            agents: agentValues.compactMap { paneRecord(from: $0) },
            hasPaneList: paneValues != nil)
    }

    public static func eventName(in text: String) -> String? {
        guard let object = firstJSON(in: text) as? [String: Any] else { return nil }
        let raw =
            string(object["event"])
            ?? (object["data"] as? [String: Any]).flatMap { string($0["type"]) }
        return raw?.replacingOccurrences(of: ".", with: "_")
    }

    public static func eventData(in text: String) -> [String: Any]? {
        (firstJSON(in: text) as? [String: Any])?["data"] as? [String: Any]
    }

    public static func eventPane(in text: String) -> HerdrPaneRecord? {
        guard let data = eventData(in: text) else { return nil }
        if let pane = data["pane"] { return paneRecord(from: pane) }
        if string(in: data, keys: ["pane_id", "pane"]) != nil {
            return paneRecord(from: data)
        }
        return nil
    }

    public static func eventPaneID(in text: String) -> String? {
        if let pane = eventPane(in: text)?.pane, !pane.isEmpty { return pane }
        guard let data = eventData(in: text) else { return nil }
        return string(in: data, keys: ["pane_id", "pane"])
    }

    public static func eventPreviousPaneID(in text: String) -> String? {
        guard let data = eventData(in: text) else { return nil }
        return string(in: data, keys: ["previous_pane_id"])
    }

    public static func eventReleased(in text: String) -> Bool {
        guard let data = eventData(in: text) else { return false }
        if let flag = data["released"] as? Bool { return flag }
        if let number = data["released"] as? NSNumber { return number.boolValue }
        return false
    }

    public static func eventAgentKind(in text: String) -> String? {
        guard let data = eventData(in: text) else { return nil }
        return string(in: data, keys: ["agent", "display_agent", "kind"])
    }

    public static func eventFinalStatus(in text: String) -> String? {
        guard let data = eventData(in: text) else { return nil }
        return string(in: data, keys: ["final_status"])
    }

    public static func eventWorkspace(in text: String) -> (id: String, label: String?)? {
        guard let data = eventData(in: text) else { return nil }
        let object = data["workspace"] as? [String: Any] ?? data
        guard let id = string(in: object, keys: ["workspace_id", "id"]) else { return nil }
        return (id, string(in: object, keys: ["label", "name"]))
    }

    public static func paneRecord(from value: Any) -> HerdrPaneRecord? {
        guard let object = value as? [String: Any] else { return nil }
        let pane =
            string(in: object, keys: ["pane_id", "pane", "id", "terminal_id", "target"]) ?? ""
        guard !pane.isEmpty else { return nil }
        return HerdrPaneRecord(
            pane: pane,
            kindRaw: string(in: object, keys: ["display_agent", "agent", "kind"]),
            statusRaw: string(
                in: object, keys: ["agent_status", "status", "state", "agentStatus"]),
            title: string(
                in: object, keys: ["terminal_title_stripped", "title", "terminal_title"]),
            workspaceID: string(in: object, keys: ["workspace_id"]),
            cwd: string(in: object, keys: ["foreground_cwd", "cwd", "working_directory"]))
    }

    public static func agent(
        from record: HerdrPaneRecord, context: HerdrBoardContext,
        workspaceLabels: [String: String], previous: HerdrAgent? = nil
    ) -> HerdrAgent {
        let kind: String
        if let raw = record.kindRaw, !raw.isEmpty {
            let named = HerdrKind.displayName(for: raw)
            if named == "Unknown", let previous, previous.kind != "Unknown" {
                kind = previous.kind
            } else {
                kind = named
            }
        } else {
            kind = previous?.kind ?? "Unknown"
        }
        let parsed = HerdrAgentStatus.parse(record.statusRaw)
        let status: HerdrAgentStatus
        if let previous, parsed == .unknown, previous.status != .unknown {
            status = previous.status
        } else {
            status = parsed
        }
        let title: String
        if let incoming = record.title, incoming != record.pane {
            title = incoming
        } else if let previous, previous.title != previous.pane, !previous.title.isEmpty {
            title = previous.title
        } else {
            title = record.title ?? previous?.title ?? record.pane
        }
        let workspaceID = record.workspaceID ?? ""
        let workspace: String
        if let labeled = workspaceLabels[workspaceID], !labeled.isEmpty {
            workspace = labeled
        } else if workspaceID.isEmpty {
            workspace = previous?.workspace ?? ""
        } else {
            workspace = workspaceID
        }
        let cwd: String
        if let incoming = record.cwd, !incoming.isEmpty {
            cwd = incoming
        } else {
            cwd = previous?.cwd ?? ""
        }
        return HerdrAgent.make(
            machineID: context.machineID, machineName: context.machineName,
            machineIsLocal: context.machineIsLocal, sshTarget: context.sshTarget,
            session: context.session, pane: record.pane, kind: kind, status: status, title: title,
            workspace: workspace, cwd: cwd)
    }

    public static func agents(
        fromSnapshot text: String, session: String, machineID: String, machineName: String,
        machineIsLocal: Bool, sshTarget: String?
    ) -> [HerdrAgent] {
        let context = HerdrBoardContext(
            session: session, machineID: machineID, machineName: machineName,
            machineIsLocal: machineIsLocal, sshTarget: sshTarget)
        guard let board = snapshotBoard(from: text) else { return [] }
        var records: [String: HerdrPaneRecord] = [:]
        for record in board.panes where record.looksLikeAgent {
            records[record.pane] = record
        }
        for record in board.agents {
            records[record.pane] = records[record.pane]?.merging(record) ?? record
        }
        return records.keys.sorted().map { pane in
            agent(
                from: records[pane]!, context: context, workspaceLabels: board.labels,
                previous: nil)
        }
    }

    public static func agents(
        from text: String, session: String, machineID: String, machineName: String,
        machineIsLocal: Bool, sshTarget: String?
    ) -> [HerdrAgent] {
        guard let json = firstJSON(in: text) else { return [] }
        let payload = unwrap(json)
        let values: [Any]
        if let array = payload as? [Any] {
            values = array
        } else if let object = payload as? [String: Any] {
            values = array(in: object, keys: ["agents", "panes", "items"]) ?? []
        } else {
            values = []
        }
        return values.compactMap { value in
            agent(
                from: value, session: session, machineID: machineID, machineName: machineName,
                machineIsLocal: machineIsLocal, sshTarget: sshTarget, workspaceLabels: [:])
        }
    }

    private static func agent(
        from value: Any, session: String, machineID: String, machineName: String,
        machineIsLocal: Bool, sshTarget: String?, workspaceLabels: [String: String]
    ) -> HerdrAgent? {
        guard let object = value as? [String: Any] else { return nil }
        let pane =
            string(
                in: object,
                keys: ["pane_id", "pane", "id", "terminal_id", "target"]) ?? ""
        guard !pane.isEmpty else { return nil }
        let kindRaw =
            string(
                in: object,
                keys: ["display_agent", "agent", "kind", "name"]) ?? ""
        let title =
            string(
                in: object,
                keys: [
                    "terminal_title_stripped", "title", "name", "summary", "terminal_title",
                ]) ?? pane
        let workspaceID =
            string(in: object, keys: ["workspace_id", "workspace", "tab_id"]) ?? ""
        let workspace = workspaceLabels[workspaceID] ?? workspaceID
        let cwd =
            string(
                in: object, keys: ["foreground_cwd", "cwd", "working_directory"]) ?? ""
        let statusRaw =
            string(in: object, keys: ["agent_status", "status", "state", "agentStatus"])
        return HerdrAgent.make(
            machineID: machineID, machineName: machineName, machineIsLocal: machineIsLocal,
            sshTarget: sshTarget, session: session, pane: pane,
            kind: HerdrKind.displayName(for: kindRaw),
            status: HerdrAgentStatus.parse(statusRaw), title: title, workspace: workspace,
            cwd: cwd)
    }

    public static func firstJSON(in text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = decode(trimmed) { return parsed }
        guard let start = trimmed.firstIndex(where: { $0 == "{" || $0 == "[" }) else {
            return nil
        }
        return decode(String(trimmed[start...]))
    }

    public static func errorMessage(in text: String) -> String? {
        guard let object = firstJSON(in: text) as? [String: Any] else { return nil }
        if let message = string(object["message"]) { return message }
        if let error = object["error"] as? [String: Any], let message = string(error["message"]) {
            return message
        }
        if let error = string(object["error"]) { return error }
        return nil
    }

    private static func unwrap(_ json: Any) -> Any {
        guard let object = json as? [String: Any] else { return json }
        if let result = object["result"] { return unwrap(result) }
        if let data = object["data"] { return unwrap(data) }
        return object
    }

    private static func decode(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func array(in object: [String: Any], keys: [String]) -> [Any]? {
        for key in keys {
            if let value = object[key] as? [Any] { return value }
        }
        return nil
    }

    private static func string(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = string(object[key]) { return value }
        }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.stringValue
        }
        return nil
    }
}
