import EdithKit
import Foundation

enum StandupNotionError: Error {
    case http(Int)
    case parse
}

enum StandupNotionClient {
    private static let version = "2025-09-03"

    static func resolveDataSourceID(databaseID: String, token: String) async throws -> String {
        let cacheKey = "standupNotionDataSourceID_\(databaseID)"
        if let cached = SharedDefaults.store.string(forKey: cacheKey) { return cached }
        var request = URLRequest(
            url: URL(string: "https://api.notion.com/v1/databases/\(databaseID)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(version, forHTTPHeaderField: "Notion-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw StandupNotionError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sources = json["data_sources"] as? [[String: Any]],
            let id = sources.first?["id"] as? String
        else {
            throw StandupNotionError.parse
        }
        SharedDefaults.store.set(id, forKey: cacheKey)
        return id
    }

    static func queryRuns(
        dataSourceID: String, token: String, tagsProperty: String, workTag: String
    ) async throws -> Data {
        var request = URLRequest(
            url: URL(string: "https://api.notion.com/v1/data_sources/\(dataSourceID)/query")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(version, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let filter: [String: Any] = [
            "property": tagsProperty,
            "multi_select": ["contains": workTag],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: ["filter": filter])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw StandupNotionError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }
}
