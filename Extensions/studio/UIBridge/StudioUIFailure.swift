import Foundation

struct StudioUIFailure: Codable, Sendable {
    let studioFailure: String
    init(_ error: Error) { studioFailure = String(error.localizedDescription.prefix(4_096)) }
}
