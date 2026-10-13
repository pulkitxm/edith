import Foundation
import Testing
@testable import EdithExtensionAccounts

@Suite struct AccountSupportModelTests {
    @Test func explicitImportChoosesOAuthThenAPIKeyThenSavedLogin() throws {
        let token = try ClaudeAccount.currentCLIAccount(environment: [
            "CLAUDE_CODE_OAUTH_TOKEN": "synthetic-token", "ANTHROPIC_API_KEY": "synthetic-key",
        ])
        #expect(token.authentication == .oauthToken && token.credential == "synthetic-token")
        let key = try ClaudeAccount.currentCLIAccount(environment: [
            "ANTHROPIC_API_KEY": "synthetic-key"
        ])
        #expect(key.authentication == .apiKey)
        let data = Data(
            "{\"claudeAiOauth\":{\"accessToken\":\"synthetic-login\",\"refreshToken\":\"synthetic-refresh\"}}"
                .utf8)
        let login = try ClaudeAccount.currentCLIAccount(environment: [:], savedLoginData: data)
        #expect(login.authentication == .browserLogin)
        #expect(login.loginData == String(decoding: data, as: UTF8.self))
        #expect(login.remoteMachineID == nil && !login.isLoggedOut)
    }

    @Test func invalidOrIncompleteAccountsRejectLaunch() throws {
        #expect(throws: ClaudeAccountError.self) { try ClaudeAccount(name: " ").validate() }
        #expect(throws: ClaudeAccountError.self) {
            try ClaudeAccount(name: "Work", credential: "bad\0token").validate()
        }
        #expect(throws: ClaudeAccountError.self) {
            try ClaudeAccount(name: "Work").validateLaunch()
        }
        try ClaudeAccount(name: "Work", authentication: .browserLogin).validateLaunch()
        #expect(throws: ClaudeAccountError.self) {
            try ClaudeAccount.currentCLIAccount(environment: [:])
        }
    }

    @Test func accountStateEnforcesUniqueIDsAndValidDefault() throws {
        let account = ClaudeAccount(name: "Synthetic", credential: "synthetic-token")
        #expect(throws: ClaudeAccountError.self) {
            try ClaudeAccountsState(accounts: [account, account]).validate()
        }
        #expect(throws: ClaudeAccountError.self) {
            try ClaudeAccountsState(accounts: [account], defaultID: UUID()).validate()
        }
        #expect(throws: ClaudeAccountError.self) {
            try ClaudeAccountsState(
                accounts: (0..<65).map { ClaudeAccount(name: "Synthetic \($0)") }
            ).validate()
        }
        try ClaudeAccountsState(accounts: [account], defaultID: account.id).validate()
    }

    @Test func remoteAssociationAndLogoutAreExplicitMetadata() throws {
        var account = ClaudeAccount(name: "Synthetic", credential: "synthetic-token")
        account.remoteMachineID = "synthetic-selected-host"
        account.isLoggedOut = true
        let decoded = try JSONDecoder().decode(
            ClaudeAccount.self, from: JSONEncoder().encode(account))
        #expect(decoded == account)
        account.remoteMachineID = ""
        #expect(throws: ClaudeAccountError.self) { try account.validate() }
    }

    @Test func linkedLimitsIdentityCannotAliasAccountsOrOtherLimitsProfiles() throws {
        var first = ClaudeAccount(name: "Synthetic first", credential: "synthetic-first")
        var second = ClaudeAccount(name: "Synthetic second", credential: "synthetic-second")
        first.limitsProfileID = UUID()
        try ClaudeAccountsState(accounts: [first, second]).validate()
        second.limitsProfileID = first.limitsProfileID
        #expect(throws: ClaudeAccountError.self) {
            try ClaudeAccountsState(accounts: [first, second]).validate()
        }
        second.limitsProfileID = nil
        first.limitsProfileID = second.id
        #expect(throws: ClaudeAccountError.self) {
            try ClaudeAccountsState(accounts: [first, second]).validate()
        }
        first.limitsProfileID = first.id
        #expect(throws: ClaudeAccountError.self) { try first.validate() }
        first.limitsProfileID = UUID()
        first.authentication = .apiKey
        #expect(throws: ClaudeAccountError.self) { try first.validate() }
        first.authentication = .browserLogin
        #expect(throws: ClaudeAccountError.self) { try first.validate() }
    }

}
