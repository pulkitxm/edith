import Foundation

struct EmbeddedMusicVideoLease: Codable, Sendable {
    var id: UUID
    var revision: UUID
    var length: Int64
    var contentType: String
    var fileExtension: String
    var position: Double
    var playing: Bool
    var volume: Double
}

struct EmbeddedMusicVideoRange: Codable, Sendable {
    var id: UUID
    var revision: UUID
    var sequence: UInt64
    var offset: Int64
    var count: Int
}

struct EmbeddedMusicVideoBytes: Codable, Sendable {
    var id: UUID
    var revision: UUID
    var sequence: UInt64
    var offset: Int64
    var data: Data
}

struct EmbeddedMusicVideoReport: Codable, Sendable {
    var id: UUID
    var revision: UUID
    var elapsed: Double
    var duration: Double
    var playing: Bool
    var volume: Double
    var controlRevision: UInt64
}

struct EmbeddedMusicVideoControl: Codable, Sendable {
    var id: UUID
    var revision: UInt64
    var playing: Bool
    var volume: Double
    var seek: Double?
}
