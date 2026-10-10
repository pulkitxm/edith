import Foundation

public struct CodeStatsReportQuery: Codable, Sendable {
    public let range: CodeStatsRange
    public let filter: CodeStatsFilter
    public init(_ range: CodeStatsRange, filter: CodeStatsFilter = .default) {
        self.range = range; self.filter = filter
    }
}

enum CodeStatsCommand {
    static let status = "codeStats.status"
    static let report = "codeStats.report"
    static let authors = "codeStats.authors"
    static let start = "codeStats.run"
    static let cancel = "codeStats.cancel"
    static let profile = "codeStats.profile"
    static let facts = "codeStats.facts"
    static let audit = "codeStats.audit"
}

struct CodeStatsFailure: LocalizedError, Equatable {
    enum Kind { case refused, unavailable, unknownOperation }
    let kind: Kind
    let message: String
    init(_ kind: Kind, _ message: String) { self.kind = kind; self.message = message }
    var errorDescription: String? { message }
}
