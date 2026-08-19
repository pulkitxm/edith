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

    public static func agents(
        fromSnapshot text: String, session: String, machineID: String, machineName: String,
        machineIsLocal: Bool, sshTarget: String?
    ) -> [HerdrAgent] {
        guard let json = firstJSON(in: text) as? [String: Any] else { return [] }
        let payload = unwrap(json) as? [String: Any] ?? [:]
        let snapshot = payload["snapshot"] as? [String: Any] ?? payload
        var labels: [String: String] = [:]
        for value in snapshot["workspaces"] as? [Any] ?? [] {
            guard let workspace = value as? [String: Any] else { continue }
            guard let id = string(in: workspace, keys: ["workspace_id", "id"]) else { continue }
            labels[id] = string(in: workspace, keys: ["label", "name"]) ?? id
        }
        let values = snapshot["agents"] as? [Any] ?? []
        return values.compactMap { value in
            agent(
                from: value, session: session, machineID: machineID, machineName: machineName,
                machineIsLocal: machineIsLocal, sshTarget: sshTarget, workspaceLabels: labels)
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
