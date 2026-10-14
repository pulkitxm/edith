import Darwin
import EdithExtensionAccounts
import Foundation
import Testing

@testable import UsageExtension

@Suite struct AccountQuotaCacheTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func fixture() throws -> URL {
        let temporary = try #require(ProcessInfo.processInfo.environment["TMPDIR"])
        let root = URL(fileURLWithPath: temporary, isDirectory: true)
            .resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    @Test func restartRetainsQuotaAndRetryWithHashedKeysButCredentialChangeRefetches()
        async throws
    {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var account = ClaudeAccount(name: "Synthetic private name", credential: "synthetic-token")
        let collector = ClaudeAccountLimitsCollector(persistCache: true)
        _ = try await collector.refresh(accounts: [account], directory: root, now: now) { _, _ in
            .init(provider: .claude, session: .init(percent: 23, resetsAt: nil), week: nil)
        }
        let failed = try await collector.refresh(
            accounts: [account], directory: root, now: now.addingTimeInterval(60)
        ) { _, _ in throw ClaudeLimitsReader.Failure.rateLimited(300) }
        let cachedData = try AccountQuotaCache.read(directory: root)
        let data = try #require(cachedData)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains(account.credential))
        #expect(!text.contains(account.name))
        #expect(!text.contains(account.id.uuidString))
        let object = try JSONSerialization.jsonObject(with: data)
        let document = try #require(object as? [String: Any])
        #expect(document.count == 1)
        #expect(document.keys.allSatisfy { $0.count == 64 })
        account.name = "Renamed synthetic account"
        let restored = try await ClaudeAccountLimitsCollector(persistCache: true).refresh(
            accounts: [account], directory: root, now: now.addingTimeInterval(61)
        ) { _, _ in
            Issue.record("Restart bypassed the persisted retry deadline")
            return .init(provider: .claude, session: nil, week: nil)
        }
        #expect(restored.first?.limits == failed.first?.limits)
        #expect(restored.first?.refreshedAt == now)
        #expect(restored.first?.retryAt == now.addingTimeInterval(360))
        #expect(restored.first?.name == account.name)
        account.credential = "synthetic-replaced-token"
        let replaced = try await ClaudeAccountLimitsCollector(persistCache: true).refresh(
            accounts: [account], directory: root, now: now.addingTimeInterval(62)
        ) { _, _ in
            .init(provider: .claude, session: .init(percent: 7, resetsAt: nil), week: nil)
        }
        #expect(replaced.first?.limits.session?.percent == 7)
        #expect(replaced.first?.refreshedAt == now.addingTimeInterval(62))
        #expect(replaced.first?.retryAt == nil)
    }

    @Test func sixtyFourActiveQuotasSurviveAnOverLimitConfigurationWithoutPartialPersistence()
        async throws
    {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = (0..<64).map {
            ClaudeAccount(name: "Synthetic \($0)", credential: "synthetic-token-\($0)")
        }
        let collector = ClaudeAccountLimitsCollector(persistCache: true)
        let original = try await collector.refresh(accounts: accounts, directory: root, now: now) {
            _, _ in .init(provider: .claude, session: .init(percent: 23, resetsAt: nil), week: nil)
        }
        let cachedData = try AccountQuotaCache.read(directory: root)
        let data = try #require(cachedData)
        let object = try JSONSerialization.jsonObject(with: data)
        let document = try #require(object as? [String: Any])
        #expect(document.count == 64)
        let tooMany = accounts + [ClaudeAccount(name: "Extra", credential: "synthetic-extra")]
        await #expect(throws: ClaudeAccountError.self) {
            _ = try await collector.refresh(accounts: tooMany, directory: root, now: now) { _, _ in
                Issue.record("Over-limit accounts started quota work")
                return .init(provider: .claude, session: nil, week: nil)
            }
        }
        #expect(try AccountQuotaCache.read(directory: root) == data)
        let retained = try await collector.refresh(
            accounts: accounts, directory: root, now: now.addingTimeInterval(1)
        ) { _, _ in
            Issue.record("Over-limit configuration removed active cached quota")
            return .init(provider: .claude, session: nil, week: nil)
        }
        #expect(retained == original)
    }

    @Test(arguments: ["over64", "foreign"])
    func excessiveSavedEntriesAndForeignProviderPayloadCannotReplaceActiveClaudeQuota(kind: String)
        async throws
    {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = ClaudeAccount(name: "Synthetic", credential: "synthetic-token")
        _ = try await ClaudeAccountLimitsCollector(persistCache: true).refresh(
            accounts: [account], directory: root, now: now
        ) { _, _ in .init(provider: .claude, session: .init(percent: 23, resetsAt: nil), week: nil)
        }
        let cachedData = try AccountQuotaCache.read(directory: root)
        let data = try #require(cachedData)
        let object = try JSONSerialization.jsonObject(with: data)
        var document = try #require(object as? [String: Any])
        let key = try #require(document.keys.first)
        var entry = try #require(document[key] as? [String: Any])
        if kind == "over64" {
            for index in 0..<64 {
                let suffix = String(index, radix: 16)
                document[String(repeating: "0", count: 64 - suffix.count) + suffix] = entry
            }
            #expect(document.count == 65)
        } else {
            var limits = try #require(entry["limits"] as? [String: Any])
            let foreign = GrokAllowance(
                period: "weekly", tier: nil, products: [], onDemandUsed: 0, onDemandCap: 0,
                prepaidBalance: 0)
            limits["grok"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(foreign))
            #expect(
                try JSONDecoder().decode(
                    LimitsProviderSnapshot.self,
                    from: JSONSerialization.data(withJSONObject: limits)
                ).grok == foreign)
            entry["limits"] = limits
            document[key] = entry
        }
        try AccountQuotaCache.write(
            JSONSerialization.data(withJSONObject: document), directory: root)
        let fresh = try await ClaudeAccountLimitsCollector(persistCache: true).refresh(
            accounts: [account], directory: root, now: now.addingTimeInterval(1)
        ) { _, _ in .init(provider: .claude, session: .init(percent: 7, resetsAt: nil), week: nil) }
        #expect(fresh.first?.limits.session?.percent == 7)
        #expect(fresh.first?.limits.grok == nil)
        #expect(fresh.first?.refreshedAt == now.addingTimeInterval(1))
        let replacementData = try AccountQuotaCache.read(directory: root)
        let replaced = try #require(replacementData)
        let savedObject = try JSONSerialization.jsonObject(with: replaced)
        let saved = try #require(savedObject as? [String: Any])
        #expect(saved.count == 1)
    }

    @Test(arguments: ["symlink", "hardlink", "public", "oversized"])
    func unsafeCacheFilesRejectReadsAndWritesWithoutReplacingTheirContents(kind: String) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(AccountQuotaCache.fileName)
        let original = Data("synthetic-preserved".utf8)
        let target = root.appendingPathComponent("synthetic-target")
        switch kind {
        case "symlink":
            try original.write(to: target)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        case "hardlink":
            try original.write(to: target)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: target.path)
            try #require(link(target.path, file.path) == 0)
        case "public":
            try original.write(to: file)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: file.path)
        default:
            try Data(repeating: 1, count: AccountQuotaCache.maximumBytes + 1).write(to: file)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        #expect(throws: ClaudeLimitsReader.Failure.self) {
            try AccountQuotaCache.read(directory: root)
        }
        #expect(throws: ClaudeLimitsReader.Failure.self) {
            try AccountQuotaCache.write(Data("synthetic-replacement".utf8), directory: root)
        }
        let retained = try Data(contentsOf: file)
        #expect(
            kind == "oversized"
                ? retained.count == AccountQuotaCache.maximumBytes + 1 : retained == original)
    }

    @Test func publicRootAndSymlinkAncestorRejectWithoutWritingCache() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        #expect(throws: ClaudeLimitsReader.Failure.self) {
            try AccountQuotaCache.write(Data(), directory: alias)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: directory.path)
        #expect(throws: ClaudeLimitsReader.Failure.self) {
            try AccountQuotaCache.write(Data(), directory: directory)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(AccountQuotaCache.fileName).path))
    }

    @Test func oversizedWritesRejectAndDefaultCollectorsLeaveTheFilesystemUntouched() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: ClaudeLimitsReader.Failure.self) {
            try AccountQuotaCache.write(
                Data(repeating: 1, count: AccountQuotaCache.maximumBytes + 1), directory: root)
        }
        _ = try await ClaudeAccountLimitsCollector().refresh(
            accounts: [.init(name: "Synthetic", credential: "synthetic-token")], directory: root,
            now: now
        ) { _, _ in .init(provider: .claude, session: nil, week: nil) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
