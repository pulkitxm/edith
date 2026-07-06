import Foundation

public enum NotionRowParsing {
    public struct Row: Equatable {
        public let title: String
        public let tags: [String]
        public let contextLine: String
        public let date: Date?
    }

    public static func parse(_ data: Data, tagsProperty: String, dateProperty: String) -> [Row] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let results = json["results"] as? [[String: Any]]
        else { return [] }
        return results.map { row($0, tagsProperty: tagsProperty, dateProperty: dateProperty) }
    }

    public static func linesInRange(_ rows: [Row], since: Date, until: Date) -> [String] {
        rows.filter { row in
            guard let date = row.date else { return true }
            return date >= since && date < until
        }.map { "- \($0.contextLine)" }
    }

    private static func row(_ page: [String: Any], tagsProperty: String, dateProperty: String)
        -> Row
    {
        let props = (page["properties"] as? [String: Any]) ?? [:]
        var title = "Untitled"
        var tags: [String] = []
        var date: Date?
        var extras: [String] = []
        for (name, raw) in props {
            guard let prop = raw as? [String: Any], let type = prop["type"] as? String else {
                continue
            }
            switch type {
            case "title":
                title = plainText(from: prop["title"]) ?? title
            case "multi_select" where name == tagsProperty:
                tags = ((prop["multi_select"] as? [[String: Any]]) ?? []).compactMap {
                    $0["name"] as? String
                }
            case "date" where name == dateProperty:
                if let start = (prop["date"] as? [String: Any])?["start"] as? String {
                    date = EdithDate.parseISO(start)
                }
            case "select":
                if let value = (prop["select"] as? [String: Any])?["name"] as? String {
                    extras.append("\(name): \(value)")
                }
            case "rich_text":
                if let value = plainText(from: prop["rich_text"]), !value.isEmpty {
                    extras.append("\(name): \(value)")
                }
            default:
                break
            }
        }
        let context = ([title] + extras.sorted()).joined(separator: " — ")
        return Row(title: title, tags: tags, contextLine: context, date: date)
    }

    private static func plainText(from richText: Any?) -> String? {
        guard let items = richText as? [[String: Any]] else { return nil }
        let text = items.compactMap { item -> String? in
            if let plain = item["plain_text"] as? String { return plain }
            return (item["text"] as? [String: Any])?["content"] as? String
        }.joined()
        return text.isEmpty ? nil : text
    }
}
