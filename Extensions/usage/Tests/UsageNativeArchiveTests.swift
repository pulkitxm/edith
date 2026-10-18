import Foundation
import Testing
@testable import UsageExtension

@Suite(.serialized) struct UsageNativeArchiveTests {
    @Test func capacityCountersTrackUpsertDeleteAndRollbackExactly() throws {
        try fixture { root in
            let archive = try UsageNativeArchive(dataDirectory: root)
            try archive.cache(["value": "mock-one"], key: "cache")
            try archive.cache(["value": "mock-two-longer"], key: "cache")
            let event = try UsageNativeParser(source: "cli").consume(
                UsageNativeJSON.object(line(id: "one").dropLast())
            ).map(\.event)
            try archive.replaceRemote(event, key: "remote", account: "one")
            let before = try archive.database.rows("SELECT bytes,records FROM capacity").first!
            #expect(before["records"] == "1")
            try archive.replaceRemote([], key: "remote", account: "one")
            let after = try archive.database.rows("SELECT bytes,records FROM capacity").first!
            #expect(after["records"] == "0")
            let actual = try archive.database.rows(
                "SELECT SUM(length(CAST(payload AS BLOB))) AS bytes FROM cloud_cache"
            ).first!["bytes"]!
            #expect(after["bytes"] == actual)
            #expect(Int(before["bytes"]!)! > Int(after["bytes"]!)!)
        }
    }

    @Test func deletedFilesRemainBilledAfterRestartAndIdenticalReplayDoesNotDuplicate() throws {
        try fixture { root in
            let path = root.appendingPathComponent("journal.jsonl")
            try line(id: "first").write(to: path)
            var archive: UsageNativeArchive? = try .init(dataDirectory: root)
            try archive!.bootstrap(nil)
            let snapshot = try UsageNativeParser(source: "cli").snapshot(
                path, key: "mock/journal", previous: nil)
            try archive!.admit(snapshot, previous: nil)
            archive = nil
            try FileManager.default.removeItem(at: path)
            let reopened = try UsageNativeArchive(dataDirectory: root)
            #expect(try reopened.events().count == 1)
            #expect(try reopened.retainedFiles(seen: []) == 1)
            try line(id: "first").write(to: path)
            let previous = try reopened.known("mock/journal")
            let replay = try UsageNativeParser(source: "cli").snapshot(
                path, key: "mock/journal", previous: previous)
            try reopened.admit(replay, previous: previous)
            #expect(try reopened.events().count == 1)
        }
    }

    @Test func anonymousRewritesBecomeUncountedCandidatesWhileLaterAppendsContinue() throws {
        try fixture { root in
            let path = root.appendingPathComponent("journal.jsonl")
            let archive = try UsageNativeArchive(dataDirectory: root)
            try archive.bootstrap(nil)
            try line(id: nil, input: 20).write(to: path)
            try admit(path, key: "journal", archive: archive)
            try (line(id: nil, input: 90) + line(id: nil, input: 90)).write(to: path)
            try admit(path, key: "journal", archive: archive)
            #expect(try archive.unresolvedCandidates() == 2)
            #expect(try archive.events().count == 1)
            try (line(id: nil, input: 90) + line(id: nil, input: 90) + line(id: nil, input: 7))
                .write(to: path)
            try admit(path, key: "journal", archive: archive)
            #expect(try archive.unresolvedCandidates() == 2)
            #expect(try archive.events().count == 2)
        }
    }

    @Test func providerIdentityVariantsAreRetainedWithoutPromptOrToolContent() throws {
        try fixture { root in
            let path = root.appendingPathComponent("journal.jsonl")
            let archive = try UsageNativeArchive(dataDirectory: root)
            try archive.bootstrap(nil)
            try (line(id: "same", input: 20) + line(id: "same", input: 25)).write(to: path)
            try admit(path, key: "journal", archive: archive)
            #expect(try archive.events().count == 2)
            let stored = try archive.database.rows("SELECT payload FROM records").compactMap {
                $0["payload"]
            }.joined()
            #expect(!stored.contains("PRIVATE_CONTENT_CANARY"))
            #expect(!stored.contains("content"))
            #expect(!stored.contains("unknownPrivateField"))
        }
    }

    @Test func independentAnonymousFilesHaveIndependentReceiptIdentity() throws {
        try fixture { root in
            let archive = try UsageNativeArchive(dataDirectory: root)
            try archive.bootstrap(nil)
            let path = root.appendingPathComponent("journal.jsonl")
            try line(id: nil).write(to: path)
            try admit(path, key: "journal-one", archive: archive)
            try admit(path, key: "journal-two", archive: archive)
            let events = try archive.events()
            #expect(events.count == 2)
            #expect(Set(events.compactMap(\.identity)).count == 2)
        }
    }

    @Test func admissionCapacityRollsBackRecordsAndFileMetadataTogether() throws {
        try fixture { root in
            var limits = UsageNativeFileLimits(); limits.records = 1
            let archive = try UsageNativeArchive(dataDirectory: root, limits: limits)
            try archive.bootstrap(nil)
            let path = root.appendingPathComponent("journal.jsonl")
            try (line(id: "one") + line(id: "two")).write(to: path)
            #expect(throws: UsageNativeFailure.self) {
                try admit(path, key: "journal", archive: archive)
            }
            #expect(try archive.events().isEmpty)
            #expect(try archive.known("journal") == nil)
        }
    }

    @Test func completeTrailingReceiptIsCountedOnceWhenItsNewlineArrives() throws {
        try fixture { root in
            let archive = try UsageNativeArchive(dataDirectory: root)
            try archive.bootstrap(nil)
            let path = root.appendingPathComponent("journal.jsonl")
            var data = line(id: nil); data.removeLast()
            try data.write(to: path)
            try admit(path, key: "journal", archive: archive)
            data.append(10); data += line(id: "next")
            try data.write(to: path)
            try admit(path, key: "journal", archive: archive)
            #expect(try archive.events().count == 2)
        }
    }

    @Test func historicalOverlapKeepsImmutableBaselineAndDistinctCandidates() throws {
        try fixture { root in
            let archive = try UsageNativeArchive(dataDirectory: root)
            let zero: [String: Any] = ["tokens": 0, "cost": 0, "bySource": [:], "byPath": [:]]
            let baseline: [String: Any] = [
                "period": "2026-09-05",
                "bySource": ["cli": [["modelName": "mock", "inputTokens": 20]]],
                "hours": (0..<24).map { _ in zero }, "projects": [],
            ]
            try archive.bootstrap(["generatedAt": "2026-09-06T00:00:00Z", "daily": [baseline]])
            #expect(
                (try archive.reconcile([baseline])["blocks"] as? [[String: Any]])?.isEmpty == true)
            let retained = try archive.reconcile([])
            let blocks = try #require(retained["blocks"] as? [[String: Any]])
            #expect(blocks.count == 1)
            #expect(blocks[0]["state"] as? String == "partial-overlap")
            #expect(
                try UsageNativeJSON.encode(blocks[0]["baseline"]!)
                    == UsageNativeJSON.encode(baseline))
            #expect((try archive.reconcile([])["blocks"] as? [[String: Any]])?.count == 1)
            #expect(try archive.database.rows("SELECT * FROM aggregate_candidates").count == 1)
        }
    }

    @Test func cachedCloudReceiptsSurviveRestartAndReplaceAtomically() throws {
        try fixture { root in
            var archive: UsageNativeArchive? = try .init(dataDirectory: root)
            try archive!.cache(
                ["version": 2, "sessions": [["id": "mock", "revision": "one"]]], key: "mock-account"
            )
            archive = nil
            let reopened = try UsageNativeArchive(dataDirectory: root)
            #expect(
                (try reopened.cached("mock-account")?["sessions"] as? [[String: Any]])?.count == 1)
            try reopened.cache(["version": 2, "sessions": []], key: "mock-account")
            #expect(
                (try reopened.cached("mock-account")?["sessions"] as? [[String: Any]])?.isEmpty
                    == true)
        }
    }

    @Test func canonicalOverlapIgnoresModelOrderAndPricingPresentationMetadata() throws {
        try fixture { root in
            let archive = try UsageNativeArchive(dataDirectory: root)
            let zero: [String: Any] = ["tokens": 0, "cost": 0, "bySource": [:], "byPath": [:]]
            let baseline: [String: Any] = [
                "period": "2026-09-05",
                "bySource": [
                    "cli": [
                        ["modelName": "second", "inputTokens": 10, "cost": 1],
                        ["modelName": "first", "outputTokens": 2, "cost": 2],
                    ]
                ], "hours": (0..<24).map { _ in zero }, "projects": [],
            ]
            try archive.bootstrap(["generatedAt": "2026-09-06T00:00:00Z", "daily": [baseline]])
            var updated = baseline
            updated["bySource"] = [
                "cli": [
                    [
                        "modelName": "first", "outputTokens": 2, "cost": 2, "costMissing": false,
                        "unpricedTokens": 0, "tokens": 2,
                    ],
                    ["modelName": "second", "inputTokens": 10, "cost": 1, "isFallback": true],
                ]
            ]
            #expect(
                (try archive.reconcile([updated])["blocks"] as? [[String: Any]])?.isEmpty == true)
            updated["bySource"] = ["cli": [["modelName": "second", "inputTokens": 11, "cost": 1]]]
            #expect((try archive.reconcile([updated])["blocks"] as? [[String: Any]])?.count == 1)
        }
    }

    private func admit(_ path: URL, key: String, archive: UsageNativeArchive) throws {
        let previous = try archive.known(key)
        let snapshot = try UsageNativeParser(source: "cli").snapshot(
            path, key: key, previous: previous)
        try archive.admit(snapshot, previous: previous)
    }

    private func line(id: String?, input: Int = 10) -> Data {
        var message: [String: Any] = [
            "model": "mock-model", "usage": ["input_tokens": input, "output_tokens": 2],
            "content": [["type": "text", "text": "PRIVATE_CONTENT_CANARY"]],
        ]
        if let id { message["id"] = id }
        return
            (try! UsageNativeJSON.encode([
                "timestamp": "2026-09-05T01:00:00Z", "sessionId": "mock-session",
                "requestId": "mock-request", "costUSD": 1, "message": message,
                "unknownPrivateField": "PRIVATE_CONTENT_CANARY",
            ])) + Data([10])
    }

    private func fixture(_ action: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "usage-native-" + UUID().uuidString)
        try UsageNativeFileIO.privateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        try action(root)
    }
}
