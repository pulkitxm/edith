import Foundation

enum BifrostFixture {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil
    }
    static var applications: [BifrostApplication] {
        [
            .init(
                name: "Fixture Notes", path: "/synthetic/Applications/Notes.app",
                bundleID: "example.notes"),
            .init(
                name: "Fixture Browser", path: "/synthetic/Applications/Browser.app",
                bundleID: "example.browser"),
        ]
    }
}
