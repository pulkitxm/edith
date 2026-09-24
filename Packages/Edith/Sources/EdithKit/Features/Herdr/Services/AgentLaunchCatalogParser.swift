import Foundation

public enum AgentLaunchCatalogParser {
    public static func catalog(_ kind: AgentLaunchKind, from output: String) -> AgentLaunchCatalog?
    {
        guard let command = kind.discoveryCommand else { return nil }
        let source = AgentLaunchSource.cli(command)
        switch kind {
        case .codex:
            let models = codexModels(from: output)
            guard !models.isEmpty else { return nil }
            return .derived(kind: kind, models: models, source: source)
        case .pi:
            let models = piModels(from: output)
            guard !models.isEmpty else { return nil }
            var catalog = kind.builtIn
            catalog.models = models
            catalog.source = source
            return catalog
        case .opencode, .cursor:
            let models =
                kind == .opencode ? opencodeModels(from: output) : cursorModels(from: output)
            guard !models.isEmpty else { return nil }
            var catalog = kind.builtIn
            catalog.models = models
            catalog.source = source
            return catalog
        case .claude, .gemini, .amp:
            return nil
        }
    }

    public static func codexModels(from output: String) -> [AgentLaunchModel] {
        guard let start = output.firstIndex(of: "{"),
            let data = String(output[start...]).data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = root["models"] as? [[String: Any]]
        else { return [] }
        var seen = Set<String>()
        let ranked = entries.compactMap { entry -> (Int, AgentLaunchModel)? in
            guard let slug = text(entry["slug"]), seen.insert(slug).inserted,
                (text(entry["visibility"]) ?? "list") == "list"
            else { return nil }
            let levels = (entry["supported_reasoning_levels"] as? [[String: Any]] ?? [])
                .compactMap { level -> AgentLaunchEffort? in
                    guard let effort = text(level["effort"]) else { return nil }
                    return AgentLaunchEffort(effort, text(level["description"]) ?? "")
                }
            let model = AgentLaunchModel(
                id: slug, name: text(entry["display_name"]) ?? slug,
                summary: text(entry["description"]) ?? "", efforts: levels,
                defaultEffort: text(entry["default_reasoning_level"]),
                fastSummary: codexFast(entry))
            return ((entry["priority"] as? NSNumber)?.intValue ?? Int.max, model)
        }
        return ranked.enumerated()
            .sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }
            .map(\.element.1)
    }

    private static func codexFast(_ entry: [String: Any]) -> String? {
        let tiers = entry["service_tiers"] as? [[String: Any]] ?? []
        if let tier = tiers.first(where: {
            text($0["id"]) == "priority" || text($0["name"])?.lowercased() == "fast"
        }) {
            return text(tier["description"]) ?? "Faster responses, uses more of your limit"
        }
        let speeds = entry["additional_speed_tiers"] as? [String] ?? []
        return speeds.contains("fast") ? "Faster responses, uses more of your limit" : nil
    }

    public static func opencodeModels(from output: String) -> [AgentLaunchModel] {
        var seen = Set<String>()
        return lines(output).compactMap { line -> AgentLaunchModel? in
            guard line.range(of: #"^[A-Za-z0-9][\w.\-]*/\S+$"#, options: .regularExpression) != nil,
                seen.insert(line).inserted,
                let slash = line.firstIndex(of: "/")
            else { return nil }
            let provider = String(line[..<slash])
            let name = String(line[line.index(after: slash)...])
            let summary = name.hasSuffix("-fast") ? "Fast variant, \(provider)" : provider
            return AgentLaunchModel(id: line, name: name, summary: summary)
        }
    }

    public static func piModels(from output: String) -> [AgentLaunchModel] {
        var seen = Set<String>()
        return lines(output).compactMap { line -> AgentLaunchModel? in
            let columns = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard columns.count >= 5, ["yes", "no"].contains(columns[4].lowercased()),
                columns[0].range(of: #"^[\w.\-]+$"#, options: .regularExpression) != nil
            else { return nil }
            let id = "\(columns[0])/\(columns[1])"
            guard seen.insert(id).inserted else { return nil }
            return AgentLaunchModel(
                id: id, name: columns[1], summary: "\(columns[0]), \(columns[2]) context",
                efforts: columns[4].lowercased() == "yes" ? AgentLaunchKind.piThinking : [])
        }
    }

    public static func cursorModels(from output: String) -> [AgentLaunchModel] {
        var seen = Set<String>()
        return lines(output).compactMap { line -> AgentLaunchModel? in
            let parts = line.components(separatedBy: " - ")
            let id = parts[0].trimmingCharacters(in: .whitespaces)
            guard id.range(of: #"^[A-Za-z0-9][\w.\-:\[\]]*$"#, options: .regularExpression) != nil,
                parts.count > 1 || !line.contains(" "), seen.insert(id).inserted
            else { return nil }
            let name =
                parts.count > 1
                ? parts.dropFirst().joined(separator: " - ")
                    .replacingOccurrences(
                        of: #"\s*\((current|default)\)\s*$"#, with: "", options: .regularExpression)
                : id
            return AgentLaunchModel(id: id, name: name.trimmingCharacters(in: .whitespaces))
        }
    }

    static func lines(_ output: String) -> [String] {
        output
            .replacingOccurrences(
                of: #"\x{1B}\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression
            )
            .replacingOccurrences(
                of: #"[\x{00}-\x{08}\x{0B}-\x{1F}\x{7F}]"#, with: "", options: .regularExpression
            )
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
