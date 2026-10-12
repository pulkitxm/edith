import EdithDocsWorker
import EdithExtensionSupport
import Foundation
import Testing

@testable import DocsExtension

@Suite(.serialized) @MainActor struct DocsAskRequestTests {
    private static let sources: [DocsSource] = [
        .init(path: "README.md", markdown: "# Reference\n\nSynthetic command reference."),
        .init(path: "herdr/README.md", markdown: "# `ed herdr`\n\nManage sessions."),
        .init(path: "herdr/ls.md", markdown: "# `ed herdr ls`\n\nLists sessions."),
    ]

    private static let invalid = [
        #""list sessions""#, "null", "[]", "{}",
        #"{"request":null}"#, #"{"request":false}"#, #"{"request":7}"#,
        #"{"request":[]}"#, #"{"request":{}}"#, #"{"request":""}"#,
        #"{"request":"  "}"#, #"{"request":"list sessions","other":true}"#,
        #"{"request":"list sessions","request":"other"}"#,
        #"{"request":"list sessions","\u0072equest":"other"}"#,
        #"{"request":"list\u0000sessions"}"#, #"{"request":"list sessions"}{}"#,
    ]

    @Test func exactRequestObjectRoundTripsEscapedQuestions() throws {
        for question in ["list sessions", "show \"sessions\"", "日本語", "list\nsessions"] {
            let request = DocsAskRequest(request: question)
            let payload = try JSONEncoder().encode(request)
            let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: String])
            #expect(object == ["request": question])
            #expect(try DocsAskRequest.decode(payload) == request)
        }
        #expect(try DocsAskRequest.decode(Data(" { \"request\" : \"list sessions\" } ".utf8)).request == "list sessions")
    }

    @Test func rejectsLegacyUnknownMissingDuplicateAndInvalidQuestions() throws {
        for text in Self.invalid {
            #expect(throws: (any Error).self) { try DocsAskRequest.decode(Data(text.utf8)) }
        }
        #expect(throws: (any Error).self) {
            try DocsAskRequest.decode(JSONEncoder().encode(DocsAskRequest(request: String(repeating: "x", count: 4097))))
        }
        #expect(throws: (any Error).self) { try DocsAskRequest.decode(Data([0xff])) }
    }

    @Test func decodedQuestionByteLimitIsIndependentOfJSONEscaping() throws {
        let question = String(repeating: "界", count: 1365) + "x"
        #expect(question.utf8.count == 4096)
        let literal = try JSONEncoder().encode(DocsAskRequest(request: question))
        let escaped = Data(("{\"request\":\"" + String(repeating: "\\u754c", count: 1365) + "x\"}").utf8)
        #expect(try DocsAskRequest.decode(literal).request == question)
        #expect(try DocsAskRequest.decode(escaped).request == question)
        #expect(escaped.count > literal.count)
        for payload in [
            try JSONEncoder().encode(DocsAskRequest(request: question + "x")),
            Data(("{\"request\":\"" + String(repeating: "\\u754c", count: 1365) + "xx\"}").utf8),
        ] {
            #expect(throws: (any Error).self) { try DocsAskRequest.decode(payload) }
        }
    }

    @Test func originalSubmitUsesClosedRequestAndOriginalEngineAnswer() async throws {
        let suite = "test.edith.docs-request." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = DocsBrowser(library: DocsLibrary(sources: Self.sources), defaults: defaults)
        var operations: [String] = []
        let bridge = DocsUIBridge { operation, payload in
            operations.append(operation)
            if operation == "docs.ui.ask" {
                #expect(try DocsAskRequest.decode(payload).request == "list sessions")
            }
            return try await DocsUIBridge.execute(operation, payload: payload, browser: engine)
        }
        let presentation = DocsBrowser(defaults: defaults, remote: bridge)
        await presentation.load()
        #expect(presentation.answer == nil)
        presentation.question = "list sessions"
        await presentation.submit(decider: nil)
        let answer = try #require(presentation.answer)
        #expect(answer.request == "list sessions")
        #expect(answer.engine == .search)
        #expect(answer.picks.first?.command.path == "ed herdr ls")
        #expect(answer.picks.first?.command.location.path == "herdr/ls.md")
        #expect(answer.picks.first?.command.summary == "Lists sessions.")
        #expect(presentation.resultsVisible && !presentation.asking)
        #expect(operations == ["docs.ui.library", "docs.ui.ask"])
        presentation.question = "unrelated synthetic question"
        presentation.questionChanged()
        #expect(!presentation.resultsVisible)
        #expect(presentation.answer?.request == "list sessions")
        presentation.moveSelection(1)
        #expect(!presentation.resultsVisible)
        #expect(operations == ["docs.ui.library", "docs.ui.ask"])
        presentation.shutdown()
        engine.shutdown()
        await presentation.drain()
        await engine.drain()
    }

    @Test func executorRejectsInvalidObjectsBeforeAnswering() async throws {
        let suite = "test.edith.docs-request-reject." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = DocsBrowser(library: DocsLibrary(sources: Self.sources), defaults: defaults)
        for text in Self.invalid {
            await #expect(throws: (any Error).self) {
                try await DocsUIBridge.execute("docs.ui.ask", payload: Data(text.utf8), browser: engine)
            }
        }
        #expect(engine.answer == nil)
        engine.shutdown()
        await engine.drain()
    }
}
