import EdithExtensionSupport
import Foundation

struct SystemAppsSnapshot: Codable, Sendable {
    let apps: [RunningAppSnapshot]
    let icons: [String: Data]
    let sortKey: String
    let ascending: Bool
    let hideApps: Bool
}
struct SystemAppsSort: Codable, Sendable { let sortKey: String; let ascending: Bool }
struct SystemAppsQuitReply: Decodable {
    let applied: Bool; let changed: Int; let targets: [RunningAppSnapshot]
}

struct SystemAppsQuitRequest: Decodable {
    let all: Bool?
    let pid: Int32?
    let query: String?
    let force: Bool
    let confirmed: Bool
    static func decode(_ data: Data) throws -> Self {
        guard let values = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(values.keys).isSubset(of: ["all", "pid", "query", "force", "confirmed"])
        else { throw ExtensionPeerError.invalidRequest }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    func selection() throws -> RunningAppSelection {
        guard [all != nil, pid != nil, query != nil].filter({ $0 }).count == 1 else {
            throw ExtensionPeerError.invalidRequest
        }
        if all == true { return .all }
        if let pid, pid > 0 { return .pid(pid) }
        if let query, !query.isEmpty, query.utf8.count <= 4096, !query.utf8.contains(0) {
            return .query(query)
        }
        throw ExtensionPeerError.invalidRequest
    }
}
