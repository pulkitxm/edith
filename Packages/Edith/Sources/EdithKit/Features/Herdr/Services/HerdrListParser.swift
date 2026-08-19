import Foundation

public enum HerdrListParser {
    public static func sessions(from text: String) -> [String] {
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
        var names: [String] = []
        for value in values {
            if let name = string(value) {
                names.append(name)
                continue
            }
            guard let object = value as? [String: Any] else { continue }
            if let name = string(in: object, keys: ["name", "session", "id", "session_name"]) {
                names.append(name)
            }
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
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
                    keys: ["title", "name", "summary", "terminal_title_stripped", "terminal_title"]
                ) ?? pane
            let workspace =
                string(in: object, keys: ["workspace_id", "workspace", "tab_id"]) ?? ""
            let cwd =
                string(in: object, keys: ["cwd", "working_directory", "foreground_cwd"]) ?? ""
            let statusRaw =
                string(in: object, keys: ["agent_status", "status", "state", "agentStatus"])
            return HerdrAgent.make(
                machineID: machineID, machineName: machineName, machineIsLocal: machineIsLocal,
                sshTarget: sshTarget, session: session, pane: pane,
                kind: HerdrKind.displayName(for: kindRaw),
                status: HerdrAgentStatus.parse(statusRaw), title: title, workspace: workspace,
                cwd: cwd)
        }
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
