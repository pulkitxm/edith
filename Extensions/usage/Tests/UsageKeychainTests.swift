import Foundation
import Testing

@testable import UsageExtension

@Suite struct UsageKeychainTests {
    @Test(arguments: [false, true])
    func readSuppressesAuthenticationAndRestoresThePreviousSetting(allowed: Bool) {
        var interaction = allowed
        var transitions: [Bool] = []
        let result = UsageKeychain.read(
            ["service": "synthetic-service"], interactionAllowed: { interaction },
            setInteractionAllowed: {
                interaction = $0
                transitions.append($0)
                return true
            },
            copyItem: {
                #expect(!interaction)
                #expect($0["service"] as? String == "synthetic-service")
                return nil
            })
        #expect(result == nil)
        #expect(interaction == allowed)
        #expect(transitions == [false, allowed])
    }

    @Test func failureToDisableAuthenticationDoesNotReadCredentials() {
        let result = UsageKeychain.read(
            [:], interactionAllowed: { true }, setInteractionAllowed: { _ in false },
            copyItem: { _ in
                Issue.record("Authentication must be disabled before a background read")
                return nil
            })
        #expect(result == nil)
    }
}
