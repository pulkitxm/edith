import EdithKit
import Foundation

public enum ExecutableLaunch {
    public enum Destination: Equatable, Sendable {
        case application
        case commandLine
        case databaseBroker
        case askpass
    }

    public static func destination(
        environment: [String: String]
    ) -> Destination {
        if environment[AskpassEntry.accountVariable]?.isEmpty == false {
            return .askpass
        }
        if environment["EDITH_DATABASE_BROKER"] == "1" {
            return .databaseBroker
        }
        if environment["EDITH_CLI"] == "1" {
            return .commandLine
        }
        return .application
    }

    public static func answerAskpass() -> Never {
        _ = AskpassEntry.runIfRequested()
        exit(1)
    }

    public static func isApplication(environment: [String: String]) -> Bool {
        destination(environment: environment) == .application
    }
}
