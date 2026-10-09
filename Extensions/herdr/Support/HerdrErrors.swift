import Foundation
import OSLog

enum HerdrLog {
    static let logger = Logger(subsystem: "com.pulkit.edith.herdr", category: "hooks")
}
public struct AgentError: LocalizedError {
    public enum Code: String { case refused, failed }
    public let code: Code
    public let message: String
    public init(_ code: Code, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}
