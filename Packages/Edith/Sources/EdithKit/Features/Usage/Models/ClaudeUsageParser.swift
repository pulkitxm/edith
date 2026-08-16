import Foundation

public enum ClaudeUsageParser {
    public struct Result: Equatable, Sendable {
        public let session: LimitWindow?
        public let week: LimitWindow?
        public let fable: LimitWindow?

        public init(session: LimitWindow?, week: LimitWindow?, fable: LimitWindow?) {
            self.session = session
            self.week = week
            self.fable = fable
        }
    }

    private struct Response: Decodable {
        struct Window: Decodable {
            let utilization: Double?
            let resetsAt: String?
            enum CodingKeys: String, CodingKey {
                case utilization
                case resetsAt = "resets_at"
            }
        }

        struct ScopedLimit: Decodable {
            struct Scope: Decodable {
                struct Model: Decodable {
                    let displayName: String?
                    enum CodingKeys: String, CodingKey {
                        case displayName = "display_name"
                    }
                }
                let model: Model?
            }
            let kind: String?
            let percent: Double?
            let resetsAt: String?
            let scope: Scope?
            enum CodingKeys: String, CodingKey {
                case kind, percent, scope
                case resetsAt = "resets_at"
            }
        }

        let fiveHour: Window?
        let sevenDay: Window?
        let limits: [ScopedLimit]?
        enum CodingKeys: String, CodingKey {
            case limits
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    public static func parse(_ data: Data) throws -> Result {
        let response = try JSONDecoder().decode(Response.self, from: data)
        return Result(
            session: window(response.fiveHour),
            week: window(response.sevenDay),
            fable: fableWindow(response.limits))
    }

    private static func window(_ raw: Response.Window?) -> LimitWindow? {
        raw.map {
            LimitWindow(percent: $0.utilization ?? 0, resetsAt: EdithDate.parseISO($0.resetsAt))
        }
    }

    private static func fableWindow(_ limits: [Response.ScopedLimit]?) -> LimitWindow? {
        let scoped = (limits ?? []).filter { $0.kind == "weekly_scoped" && $0.scope?.model != nil }
        let match =
            scoped.first {
                $0.scope?.model?.displayName?.caseInsensitiveCompare("Fable") == .orderedSame
            }
            ?? scoped.first
        return match.map {
            LimitWindow(percent: $0.percent ?? 0, resetsAt: EdithDate.parseISO($0.resetsAt))
        }
    }
}
