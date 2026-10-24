import Darwin
import Foundation
import Testing

@testable import EdithExtensionAccounts

@Suite struct AccountSupportCompatibilityTests {
    private let accountID = UUID(uuidString: "0E6F2A4C-8B1D-4F3A-9C2E-5D7B8A9F0123")!
    private let tokenAccountID = UUID(uuidString: "6B1C9D2E-3F4A-4B5C-8D6E-7F8091A2B3C4")!
    private let limitsID = UUID(uuidString: "A1B2C3D4-E5F6-4711-8899-AABBCCDDEEFF")!
    private let pendingID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    private var accountsJSON: String {
        """
        {"accounts":[{"id":"\(accountID.uuidString)","name":"Synthetic browser","authentication":"browserLogin","credential":"synthetic-access","loginData":"{\\"claudeAiOauth\\":{\\"accessToken\\":\\"synthetic-access\\"}}","remoteMachineID":"6F0D3E9A-1B2C-4D5E-8F70-112233445566","isLoggedOut":false},{"id":"\(tokenAccountID.uuidString)","name":"Synthetic token","authentication":"oauthToken","credential":"synthetic-token","limitsProfileID":"\(limitsID.uuidString)","isLoggedOut":false}],"defaultID":"\(tokenAccountID.uuidString)"}
        """
    }

    private var cleanupJSON: String {
        """
        [{"accountID":"\(tokenAccountID.uuidString)","profileID":"\(pendingID.uuidString)","isConnecting":false}]
        """
    }

    private func fixture() throws -> URL {
        let temporary = try #require(ProcessInfo.processInfo.environment["TMPDIR"])
        let physical = try #require(realpath(temporary, nil))
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func write(_ text: String, name: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        #expect(
            FileManager.default.createFile(
                atPath: url.path, contents: Data(text.utf8),
                attributes: [.posixPermissions: 0o600]))
    }

    @Test func extensionEraAccountsFileDecodesAndRoundTrips() throws {
        let state = try JSONDecoder().decode(
            ClaudeAccountsState.self, from: Data(accountsJSON.utf8))
        try state.validate()
        #expect(state.accounts.count == 2)
        #expect(state.defaultID == tokenAccountID)
        let browser = state.accounts[0]
        #expect(browser.id == accountID && browser.authentication == .browserLogin)
        #expect(browser.remoteMachineID == "6F0D3E9A-1B2C-4D5E-8F70-112233445566")
        #expect(browser.limitsProfileID == nil && !browser.isLoggedOut)
        #expect(state.accounts[1].limitsProfileID == limitsID)
        let encoded = try JSONEncoder().encode(state)
        let object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let accounts = try #require(object["accounts"] as? [[String: Any]])
        #expect(
            Set(accounts[0].keys) == [
                "id", "name", "authentication", "credential", "loginData", "remoteMachineID",
                "isLoggedOut",
            ])
        #expect(accounts[1]["limitsProfileID"] as? String == limitsID.uuidString)
        #expect(object["defaultID"] as? String == tokenAccountID.uuidString)
        #expect(try JSONDecoder().decode(ClaudeAccountsState.self, from: encoded) == state)
    }

    @Test func storageReadsExtensionEraFilesAndCleansListedProfiles() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try write(accountsJSON, name: "accounts.json", in: directory)
        try write(cleanupJSON, name: "limits-cleanup.json", in: directory)
        let store = ClaudeAccountStorage(directory: directory)
        let state = try await store.load()
        #expect(state.accounts.map(\.id) == [accountID, tokenAccountID])
        let erased = ClaudeAccountCompatibilityRecorder()
        let remaining = try await store.forget(
            id: tokenAccountID, eraseScopedSecret: { erased.record($0) })
        #expect(remaining.accounts.map(\.id) == [accountID] && remaining.defaultID == nil)
        #expect(
            erased.values
                == [tokenAccountID, limitsID, pendingID].map {
                    directory.appendingPathComponent($0.uuidString, isDirectory: true)
                })
        let cleanup = try Data(contentsOf: directory.appendingPathComponent("limits-cleanup.json"))
        #expect(String(decoding: cleanup, as: UTF8.self) == "[]")
    }
}

private final class ClaudeAccountCompatibilityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []
    var values: [URL] { lock.withLock { stored } }
    func record(_ url: URL) { lock.withLock { stored.append(url) } }
}
