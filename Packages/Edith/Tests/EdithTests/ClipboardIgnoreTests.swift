import Testing

@testable import EdithKit

@Suite struct ClipboardIgnoreTests {
    @Test func knownPasswordManagerIsIgnored() {
        #expect(ClipboardIgnore.isIgnored(bundleID: "com.1password.1password", userList: []))
    }

    @Test func userListMatchIsIgnored() {
        #expect(
            ClipboardIgnore.isIgnored(
                bundleID: "com.example.secretvault", userList: ["com.example.secretvault"]))
    }

    @Test func unlistedAppIsNotIgnored() {
        #expect(!ClipboardIgnore.isIgnored(bundleID: "com.apple.TextEdit", userList: []))
    }

    @Test func nilOrEmptyBundleIDIsNotIgnored() {
        #expect(!ClipboardIgnore.isIgnored(bundleID: nil, userList: ["com.1password.1password"]))
        #expect(!ClipboardIgnore.isIgnored(bundleID: "", userList: []))
    }

    @Test func parseUserListTrimsAndDropsEmpties() {
        let parsed = ClipboardIgnore.parseUserList(" com.a.b , com.c.d ,, ")
        #expect(parsed == ["com.a.b", "com.c.d"])
    }
}
