import Foundation

public enum ExecutableLaunch {
    public enum Destination: Equatable, Sendable {
        case application
        case commandLine
        case databaseBroker
    }

    public static func destination(
        environment: [String: String]
    ) -> Destination {
        if environment["EDITH_DATABASE_BROKER"] == "1" {
            return .databaseBroker
        }
        if environment["EDITH_CLI"] == "1" {
            return .commandLine
        }
        return .application
    }

    public static func isApplication(environment: [String: String]) -> Bool {
        destination(environment: environment) == .application
    }
}
