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
}
