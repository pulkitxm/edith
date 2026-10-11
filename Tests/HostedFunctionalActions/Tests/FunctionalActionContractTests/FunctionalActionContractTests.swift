import CryptoKit
import Foundation
import FunctionalActionContract
import Testing

struct FunctionalActionContractTests {
    private let source = String(repeating: "a", count: 40)
    private let session = "12345678-1234-4123-8123-123456789abc"
    private let hash = String(repeating: "b", count: 64)

    private func object() -> [String: Any] {
        let root = "/private/synthetic/functional-fixture-" + session
        func peer(_ pid: Int) -> [String: Any] {
            [
                "pid": pid, "birthSeconds": 1000, "birthMicroseconds": pid, "uid": 501,
                "executableSHA256": hash,
            ]
        }
        return [
            "schema": 1, "sourceCommit": source, "session": session, "owner": "keepAwake",
            "uid": 501, "fixtureRoot": root,
            "hostIdentifier": "com.pulkit.edith.tests.worker-" + session,
            "home": root + "/keepAwake-home", "dataDirectory": root + "/data/keepAwake",
            "hostABI": "edith-host-2", "caseSHA256": hash,
            "activationOperation": "keepAwake.ui.update", "phase": "initial",
            "pairScope": "synthetic-development", "previousVersion": "1.0.0",
            "currentVersion": "1.1.0", "version": "1.0.0", "packageSHA256": hash,
            "engine": peer(10), "ui": peer(11), "operations": ["keepAwake.ui.update"],
            "ownedPaths": [
                ["name": "data", "path": root + "/data/keepAwake", "kind": "directory"]
            ],
        ]
    }

    private func decode(_ object: [String: Any]) throws -> HostedFunctionalActionContext {
        try HostedFunctionalActionContext.decode(
            JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
    }

    private func validate(_ context: HostedFunctionalActionContext) throws {
        try context.validate(
            source: source, owner: "keepAwake", session: session, uid: 501,
            root: "/private/synthetic/functional-fixture-" + session, caseSHA256: hash,
            engine: .init(
                pid: 10, birthSeconds: 1000, birthMicroseconds: 10, uid: 501,
                executableSHA256: hash),
            ui: .init(
                pid: 11, birthSeconds: 1000, birthMicroseconds: 11, uid: 501,
                executableSHA256: hash))
    }

    @Test func exactContextAndOperationClosure() throws {
        let context = try decode(object())
        try validate(context)
        try context.requireOperation("keepAwake.ui.update")
        #expect(throws: (any Error).self) { try context.requireOperation("system.arbitrary") }
        #expect(
            try context.ownedPath(named: "data", kind: "directory").path.hasSuffix(
                "/data/keepAwake"))
        #expect(throws: (any Error).self) {
            try context.ownedPath(named: "foreign", kind: "directory")
        }
        #expect(HostedFunctionalActionContext.owners.count == 39)
    }

    @Test func sourceOwnerSessionIdentityAndPathNegatives() throws {
        let mutations: [[String: Any]] = [
            ["sourceCommit": String(repeating: "c", count: 40)], ["owner": "music"],
            ["session": "foreign"], ["uid": 502], ["home": "/Users/actual"],
            ["dataDirectory": "/private/synthetic/functional-fixture-" + session + "/../data"],
            ["hostABI": "foreign"], ["version": "1.1.0"], ["currentVersion": "1.0.0"],
            ["previousVersion": "01.0.0"],
            ["operations": ["keepAwake.ui.update", "keepAwake.ui.update"]],
        ]
        for mutation in mutations {
            var value = object()
            value.merge(mutation) { _, new in new }
            let context = try decode(value)
            #expect(throws: (any Error).self) { try validate(context) }
        }
    }

    @Test func closedCanonicalDecoderRejectsUnknownDuplicateAndEscapedDuplicateFields() throws {
        var value = object()
        value["unreviewed"] = true
        #expect(throws: (any Error).self) { try decode(value) }
        let bytes = try JSONSerialization.data(
            withJSONObject: object(), options: [.sortedKeys, .withoutEscapingSlashes])
        let text = String(decoding: bytes, as: UTF8.self)
        for key in ["owner", "\\u006fwner"] {
            let duplicate = "{\"" + key + "\":\"foreign\"," + text.dropFirst()
            #expect(throws: (any Error).self) {
                try HostedFunctionalActionContext.decode(Data(duplicate.utf8))
            }
        }
    }

    @Test func publicPairAllowsActualLowerVersionsWithoutSyntheticStampClaim() throws {
        var value = object()
        value["pairScope"] = "public-signed-pair"
        value["previousVersion"] = "2.3.7"
        value["currentVersion"] = "2.4.1"
        value["version"] = "2.3.7"
        try validate(decode(value))
        value["currentVersion"] = "2.2.9"
        #expect(throws: (any Error).self) { try validate(decode(value)) }
    }

    @Test func wireObjectRejectsDuplicateEscapedAndNestedFields() throws {
        let good = Data("{\"operation\":\"keepAwake.ui.update\",\"nested\":{\"value\":true}}".utf8)
        #expect(
            try HostedFunctionalJSON.object(good)["operation"] as? String == "keepAwake.ui.update")
        for text in [
            "{\"presentationID\":\"one\",\"presentationID\":\"two\"}",
            "{\"presentationID\":\"one\",\"\\u0070resentationID\":\"two\"}",
            "{\"nested\":{\"value\":1,\"value\":2}}",
            "{\"array\":[{\"value\":1,\"\\u0076alue\":2}]}",
            "[1,2]",
        ] {
            #expect(throws: (any Error).self) { try HostedFunctionalJSON.object(Data(text.utf8)) }
        }
    }

    private func journalObject() throws -> [String: Any] {
        let context = object()
        let engine = context["engine"]!
        let ui = context["ui"]!
        let payload = Data("{\"values\":true}".utf8)
        let payloadHash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        func record(_ index: Int) -> [String: Any] {
            let requestID = "12345678-1234-4123-8123-123456789ac" + String(index)
            let beforeID = "12345678-1234-4123-8123-123456789ad" + String(index)
            let afterID = "12345678-1234-4123-8123-123456789ae" + String(index)
            let sequence = 3 + 4 * index
            let request: [String: Any] = [
                "schema": 1, "sourceCommit": source, "session": session, "owner": "keepAwake",
                "phase": "initial", "capabilitySHA256": hash, "requestID": requestID,
                "operation": "keepAwake.ui.update", "payloadSHA256": payloadHash,
            ]
            let before = String(repeating: index == 0 ? "1" : "0", count: 64)
            let after = String(repeating: index == 0 ? "0" : "1", count: 64)
            return [
                "request": request, "activationID": session,
                "origin": "authenticated-original-control",
                "ui": ui, "engine": engine, "payload": payload.base64EncodedString(),
                "sendSequence": sequence + 1,
                "acknowledgement": [
                    "request": request, "engine": engine, "success": true,
                    "responseSHA256": hash, "sequence": sequence + 2,
                ],
                "transition": [
                    "kind": "state-transition", "reader": "independent-hosted-producer",
                    "capabilitySHA256": hash, "requestID": requestID,
                    "before": [
                        "observationID": beforeID, "sequence": sequence,
                        "observationSHA256": before, "expectedSHA256": before,
                    ],
                    "after": [
                        "observationID": afterID, "sequence": sequence + 3,
                        "observationSHA256": after, "expectedSHA256": after,
                    ],
                ],
            ]
        }
        return [
            "schema": 1, "sourceCommit": source, "session": session, "owner": "keepAwake",
            "phase": "initial", "capabilitySHA256": hash, "presentationID": session,
            "baseline": [
                "reader": "independent-hosted-producer", "observationID": session,
                "sequence": 1, "readbackSHA256": hash, "expectedSHA256": hash,
            ],
            "loadSequence": 2, "records": [record(0), record(1)], "sealedThroughSequence": 13,
        ]
    }

    private func verifyJournal(_ object: [String: Any], key: Curve25519.Signing.PrivateKey) throws
        -> HostedFunctionalMutationJournal
    {
        let payload = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes])
        let envelope = try JSONSerialization.data(
            withJSONObject: [
                "schema": 1, "payload": String(decoding: payload, as: UTF8.self),
                "signature": try key.signature(for: payload).base64EncodedString(),
            ], options: [.sortedKeys, .withoutEscapingSlashes])
        return try HostedFunctionalMutationJournal.verify(
            envelope, issuerKey: key.publicKey.rawRepresentation)
    }

    private func validateJournal(_ journal: HostedFunctionalMutationJournal) throws {
        _ = try journal.validate(
            context: decode(object()), capabilitySHA256: hash,
            presentationID: session, persistenceApplicable: true, mutationKind: "state-transition",
            payloadKeys: ["values"], selectedRequestID: "12345678-1234-4123-8123-123456789ac1",
            persistenceSequence: 12)
    }

    @Test func independentJournalAdmitsDistinctFirstAndFinalMutation() throws {
        let key = Curve25519.Signing.PrivateKey()
        let journal = try verifyJournal(journalObject(), key: key)
        try validateJournal(journal)
        #expect(journal.records[0].request.requestID != journal.records[1].request.requestID)
    }

    @Test func journalRejectsUnknownAuthorityAndEarlyLoad() throws {
        let key = Curve25519.Signing.PrivateKey()
        for patch: [String: Any] in [
            ["sourceCommit": String(repeating: "c", count: 40)], ["loadSequence": 1],
            ["sealedThroughSequence": 10], ["beforeFirstMutation": true], ["phase": "updated"],
            ["capabilitySHA256": String(repeating: "c", count: 64)],
        ] {
            var changed = try journalObject()
            changed.merge(patch) { _, value in value }
            #expect(throws: (any Error).self) {
                try validateJournal(verifyJournal(changed, key: key))
            }
        }
        var missing = try journalObject()
        var records = missing["records"] as! [[String: Any]]
        records.reverse()
        missing["records"] = records
        #expect(throws: (any Error).self) { try validateJournal(verifyJournal(missing, key: key)) }
        records = Array(repeating: records[0], count: 129)
        missing["records"] = records
        #expect(throws: (any Error).self) { try validateJournal(verifyJournal(missing, key: key)) }
    }
}
