import EdithExtensionSupport
import Foundation
import Testing

@testable import CodeStatsExtension

@Suite @MainActor struct CodeStatsFolderRequestTests {
    @Test func exactFolderObjectRoundTripsEscapedPaths() throws {
        for folder in ["/synthetic/repository", "/synthetic/a\"b", "/synthetic/日本語", "/synthetic/a\\b"] {
            let request = CodeStatsFolderRequest(folder: folder)
            let payload = try JSONEncoder().encode(request)
            let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: String])
            #expect(object == ["folder": folder])
            #expect(try CodeStatsFolderRequest.decode(payload) == request)
        }
        #expect(try CodeStatsFolderRequest.decode(Data(" { \"folder\" : \"/synthetic/repository\" } ".utf8)).folder == "/synthetic/repository")
    }

    @Test func rejectsLegacyUnknownMissingDuplicateAndInvalidFolderValues() throws {
        let invalid = [
            #""/synthetic/repository""#, "null", "[]", "{}",
            #"{"folder":null}"#, #"{"folder":false}"#, #"{"folder":7}"#,
            #"{"folder":[]}"#, #"{"folder":{}}"#, #"{"folder":""}"#,
            #"{"folder":"  "}"#, #"{"folder":"/synthetic","other":true}"#,
            #"{"folder":"/synthetic","folder":"/other"}"#,
            #"{"folder":"/synthetic","\u0066older":"/other"}"#,
            #"{"folder":"/synthetic\u0000bad"}"#,
            #"{"folder":"/synthetic"}{}"#,
        ]
        for text in invalid {
            #expect(throws: (any Error).self) {
                try CodeStatsFolderRequest.decode(Data(text.utf8))
            }
        }
        #expect(throws: (any Error).self) {
            try CodeStatsFolderRequest.decode(JSONEncoder().encode(CodeStatsFolderRequest(folder: String(repeating: "x", count: 4097))))
        }
        #expect(throws: (any Error).self) {
            try CodeStatsFolderRequest.decode(Data([0xff]))
        }
    }

    @Test func decodedFolderByteLimitIsIndependentOfJSONEscaping() throws {
        let folder = "/" + String(repeating: "界", count: 1365)
        #expect(folder.utf8.count == 4096)
        let literal = try JSONEncoder().encode(CodeStatsFolderRequest(folder: folder))
        let escaped = Data(("{\"folder\":\"/" + String(repeating: "\\u754c", count: 1365) + "\"}").utf8)
        #expect(try CodeStatsFolderRequest.decode(literal).folder == folder)
        #expect(try CodeStatsFolderRequest.decode(escaped).folder == folder)
        #expect(escaped.count > literal.count)
        for payload in [
            try JSONEncoder().encode(CodeStatsFolderRequest(folder: folder + "x")),
            Data(("{\"folder\":\"/" + String(repeating: "\\u754c", count: 1365) + "x\"}").utf8),
        ] {
            #expect(throws: (any Error).self) { try CodeStatsFolderRequest.decode(payload) }
        }
    }

    @Test func originalChooseFolderRoutesObjectThroughBridgeAndReloadsStatus() async throws {
        let suite = "test.edith.folder-request." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = "/synthetic/repository"
        var operations: [String] = []
        let bridge = CodeStatsUIBridge { operation, payload in
            operations.append(operation)
            switch operation {
            case "codeStats.ui.folder":
                #expect(try CodeStatsFolderRequest.decode(payload).folder == folder)
                return Data("{}".utf8)
            case "codeStats.ui.status":
                #expect(payload == Data("{}".utf8))
                var status = CodeStatsPageFixture.status()
                status.settings.folder = folder
                return try JSONEncoder().encode(status)
            default: throw ExtensionPeerError.invalidRequest
            }
        }
        let model = CodeStatsModel(service: bridge.service, remote: bridge, defaults: defaults)
        await model.chooseFolder(folder)
        #expect(model.errorMessage == nil)
        #expect(model.status?.settings.folder == folder)
        #expect(operations == ["codeStats.ui.folder", "codeStats.ui.status"])
        model.cancelLoading()
    }
}
