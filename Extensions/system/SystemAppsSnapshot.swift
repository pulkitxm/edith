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
