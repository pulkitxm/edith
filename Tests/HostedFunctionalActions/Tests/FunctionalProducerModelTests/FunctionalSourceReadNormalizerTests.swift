import Foundation
import Testing
@testable import FunctionalProducerModels

struct FunctionalSourceReadNormalizerTests {
    private func policy(_ normalizer: [String: Any], owner: String = "jev") throws -> Data {
        try FunctionalBytes.canonical(["schema": 1, "owner": owner, "normalizer": normalizer])
    }

    @Test func retainsActualArrayAndObjectValues() throws {
        let definition = try policy(["kind": "identity"])
        for actual: Any in [["rows": [1, 2], "enabled": true] as [String: Any], ["one", "two"]] {
            let wire = try JSONSerialization.data(withJSONObject: actual)
            #expect(
                try FunctionalFileScopes.normalizeActualRead(
                    wire, owner: "jev", definition: definition) == FunctionalBytes.canonical(actual)
            )
        }
        #expect(throws: (any Error).self) {
            try FunctionalFileScopes.normalizeActualRead(
                Data("true".utf8), owner: "jev", definition: definition)
        }
    }

    @Test func masksActualSecretAndDecodesActualNestedData() throws {
        let history = try FunctionalBytes.canonical([["id": "synthetic-item", "enabled": true]])
        let actual = try FunctionalBytes.canonical([
            "packet": [
                "secret": "synthetic-private-value", "history": history.base64EncodedString(),
            ],
            "rows": [["name": "synthetic-first"]],
        ])
        let definition = try policy([
            "kind": "select-object",
            "fields": [
                "credential": ["path": ["packet", "secret"], "transform": "sha256-string"],
                "history": ["path": ["packet", "history"], "transform": "base64-json"],
                "first": ["path": ["rows", 0, "name"], "transform": "identity"],
            ],
        ])
        let normalized = try FunctionalFileScopes.normalizeActualRead(
            actual, owner: "jev", definition: definition)
        let object = try FunctionalBytes.object(normalized)
        #expect(object["first"] as? String == "synthetic-first")
        #expect(try FunctionalBytes.canonical(object["history"]!) == history)
        #expect(
            (object["credential"] as? [String: String]) == [
                "maskedSHA256": FunctionalBytes.digest(Data("synthetic-private-value".utf8))
            ])
        #expect(!String(decoding: normalized, as: UTF8.self).contains("synthetic-private-value"))
    }

    @Test func rejectsMissingWrongTypedAndUnknownSelections() throws {
        let actual = try FunctionalBytes.canonical(["rows": ["synthetic-first"], "number": 3])
        let fields: [[String: Any]] = [
            ["path": ["missing"], "transform": "identity"],
            ["path": ["rows", true], "transform": "identity"],
            ["path": ["rows", -1], "transform": "identity"],
            ["path": ["rows", 1], "transform": "identity"],
            ["path": ["number"], "transform": "sha256-string"],
            ["path": ["rows", 0], "transform": "base64-json"],
            ["path": ["number"], "transform": "unknown"],
            ["path": ["number"], "transform": "identity", "expected": 4],
        ]
        for field in fields {
            let definition = try policy(["kind": "select-object", "fields": ["value": field]])
            #expect(throws: (any Error).self) {
                try FunctionalFileScopes.normalizeActualRead(
                    actual, owner: "jev", definition: definition)
            }
        }
    }

    @Test func decodesOriginalPropertyListAndSelectsOriginalScalar() throws {
        let scalar = try policy(
            [
                "kind": "select-object",
                "fields": ["preferredKind": ["path": [], "transform": "identity"]],
            ], owner: "homebrew")
        let actualScalar = Data("\"cask\"".utf8)
        #expect(
            try FunctionalFileScopes.normalizeActualRead(
                actualScalar, owner: "homebrew", definition: scalar)
                == FunctionalBytes.canonical(["preferredKind": "cask"]))
        let definition = try policy(
            [
                "kind": "select-object",
                "fields": [
                    "preferences": ["path": ["preferences"], "transform": "base64-property-list"]
                ],
            ], owner: "systemStats")
        let preferences: [String: Any] = [
            "menuBarStatsColorMode": "custom", "enabled": true, "level": 4,
        ]
        let encoded = try PropertyListSerialization.data(
            fromPropertyList: preferences, format: .binary, options: 0)
        let packet = try FunctionalBytes.canonical(["preferences": encoded.base64EncodedString()])
        #expect(
            try FunctionalFileScopes.normalizeActualRead(
                packet, owner: "systemStats", definition: definition)
                == FunctionalBytes.canonical(["preferences": preferences]))
        for invalid: Any in [
            ["private": Data("synthetic".utf8)] as [String: Any],
            ["date": Date(timeIntervalSince1970: 0)] as [String: Any],
        ] {
            let encoded = try PropertyListSerialization.data(
                fromPropertyList: invalid, format: .binary, options: 0)
            let packet = try FunctionalBytes.canonical([
                "preferences": encoded.base64EncodedString()
            ])
            #expect(throws: (any Error).self) {
                try FunctionalFileScopes.normalizeActualRead(
                    packet, owner: "systemStats", definition: definition)
            }
        }
        let disguisedJSON = try FunctionalBytes.canonical([
            "preferences": Data("{}".utf8).base64EncodedString()
        ])
        #expect(throws: (any Error).self) {
            try FunctionalFileScopes.normalizeActualRead(
                disguisedJSON, owner: "systemStats", definition: definition)
        }
    }

    @Test func rejectsForeignOwnerAndOpenNormalizer() throws {
        let actual = try FunctionalBytes.canonical(["state": "synthetic-ready"])
        for definition in [
            try policy(["kind": "identity"], owner: "calendar"),
            try policy(["kind": "identity", "expected": "synthetic-ready"]),
            try policy(["kind": "select-object", "fields": [:]]),
        ] {
            #expect(throws: (any Error).self) {
                try FunctionalFileScopes.normalizeActualRead(
                    actual, owner: "jev", definition: definition)
            }
        }
    }
}
