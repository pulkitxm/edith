import Foundation
public protocol JevDeciding: Sendable {
    func decide(_ request: JevRequest, purpose: String) async throws -> JevDecision
}
