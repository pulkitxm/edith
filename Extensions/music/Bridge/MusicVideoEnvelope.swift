import Foundation

struct MusicVideoLease: Codable, Sendable {
    var id: UUID
    var revision: UUID
    var length: Int64
    var contentType: String
    var fileExtension: String
    var position: Double
    var playing: Bool
    var volume: Double
}

struct MusicVideoRange: Codable, Sendable {
    var id: UUID
    var revision: UUID
    var sequence: UInt64
    var offset: Int64
    var count: Int
}

struct MusicVideoBytes: Codable, Sendable {
    var id: UUID
    var revision: UUID
    var sequence: UInt64
    var offset: Int64
    var data: Data
}

struct MusicVideoReport: Codable, Sendable {
    var id: UUID
    var revision: UUID
    var elapsed: Double
    var duration: Double
    var playing: Bool
    var volume: Double
    var controlRevision: UInt64
}

struct MusicVideoControl: Codable, Sendable {
    var id: UUID
    var revision: UInt64
    var playing: Bool
    var volume: Double
    var seek: Double?
}
