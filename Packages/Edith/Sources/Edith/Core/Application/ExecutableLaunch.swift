import Foundation

public enum ExecutableLaunch {
    public static func isApplication(environment: [String: String]) -> Bool {
        environment["EDITH_CLI"] != "1"
    }
}
