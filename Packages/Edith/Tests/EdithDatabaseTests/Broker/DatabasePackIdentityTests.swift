import Testing

@testable import EdithDatabase

@Suite struct DatabasePackIdentityTests {
    @Test func counterpartsSwapThePackSuffix() {
        #expect(
            DatabasePackIdentity.counterpartIdentifier(for: "com.pulkit.edith")
                == "com.pulkit.edith.database")
        #expect(
            DatabasePackIdentity.counterpartIdentifier(for: "com.pulkit.edith.dev.slot")
                == "com.pulkit.edith.dev.slot.database")
        #expect(
            DatabasePackIdentity.counterpartIdentifier(for: "com.pulkit.edith.database")
                == "com.pulkit.edith")
        #expect(DatabasePackIdentity.counterpartIdentifier(for: ".database") == nil)
        #expect(DatabasePackIdentity.counterpartIdentifier(for: "") == nil)
    }

    @Test func requirementPinsTheTeamWhenPresent() {
        #expect(
            DatabasePackIdentity.requirement(
                identifier: "com.pulkit.edith.database",
                teamIdentifier: "TEAMID")
                == "identifier \"com.pulkit.edith.database\" and anchor apple generic and certificate leaf[subject.OU] = \"TEAMID\""
        )
        #expect(
            DatabasePackIdentity.requirement(
                identifier: "com.pulkit.edith.database",
                teamIdentifier: nil) == "identifier \"com.pulkit.edith.database\"")
        #expect(
            DatabasePackIdentity.requirement(
                identifier: "com.pulkit.edith.database",
                teamIdentifier: "") == "identifier \"com.pulkit.edith.database\"")
        #expect(
            DatabasePackIdentity.acceptedPeerRequirement(
                signingIdentifier: "com.pulkit.edith",
                teamIdentifier: "TEAMID")
                == "(identifier \"com.pulkit.edith\" or identifier \"com.pulkit.edith.database\") and anchor apple generic and certificate leaf[subject.OU] = \"TEAMID\""
        )
    }
}
