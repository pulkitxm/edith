import Foundation

struct BlitzTreeUISnapshot: Codable {
    let report: BlitzTreeReport?
    let root: String?
    let history: [String]
    let previewToken: UUID
    let scanning: Bool
    let removing: Bool
    let scannedEntries: UInt64
    let error: String?
}
struct BlitzTreeUITrash: Codable { let path: String; let confirmed: Bool; let previewToken: UUID }
