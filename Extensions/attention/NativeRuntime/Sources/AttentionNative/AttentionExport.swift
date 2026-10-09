import Foundation

enum AttentionExportFormat: String, Codable, Sendable { case json, csv }
struct AttentionExportRequest: Codable, Sendable {
    var from: Date
    var to: Date
    var format: AttentionExportFormat
}

enum AttentionExport {
    static func render(_ events: [AttentionEvent], format: AttentionExportFormat) throws -> Data {
        try Task.checkCancellation()
        let result: Data
        switch format {
        case .json: result = try AttentionPayload.encode(events)
        case .csv:
            let date = ISO8601DateFormatter()
            var lines = ["startedAt,duration,source,presence,application,bundleID,domain,url,title"]
            for event in events {
                try Task.checkCancellation()
                lines.append(
                    [
                        date.string(from: event.startedAt), String(event.duration),
                        event.source.rawValue, event.presence.rawValue, event.appName ?? "",
                        event.bundleID ?? "", event.domain ?? "", event.url ?? "",
                        event.windowTitle ?? "",
                    ].map(csv).joined(separator: ","))
            }
            result = Data((lines.joined(separator: "\n") + "\n").utf8)
        }
        guard result.count <= 8 * 1_024 * 1_024 else {
            throw AttentionServiceError(
                "Select a shorter period to export less than 8 MiB of activity.")
        }
        return result
    }
    static func csv(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n")
            || value.contains("\r")
        {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
