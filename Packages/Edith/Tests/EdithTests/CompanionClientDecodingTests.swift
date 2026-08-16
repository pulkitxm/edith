import Foundation
import Testing

@testable import EdithKit

@Suite struct CompanionClientDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func writeCoreAckDecodesWhatTheServerActuallySends() throws {
        let ack = try decode(CompanionWriteAck.self, #"{"section":"identity","ok":true}"#)
        #expect(ack.ok)
        #expect(ack.section == "identity")
        #expect(ack.id == nil)
    }

    @Test func discrepancyOverrideAckDecodesWhatTheServerActuallySends() throws {
        let ack = try decode(
            CompanionWriteAck.self, #"{"id":"6f1b0f8e-0000-4000-8000-000000000000","ok":true}"#)
        #expect(ack.ok)
        #expect(ack.id == "6f1b0f8e-0000-4000-8000-000000000000")
        #expect(ack.section == nil)
    }

    @Test func aServerErrorReadsAsItsSentenceNotItsEnvelope() {
        let error = CompanionClientError.badResponse(
            412, "no reasoning provider is configured on the companion")
        #expect(
            error.errorDescription == "no reasoning provider is configured on the companion")
    }

    @Test func anEmptyDetailStillNamesTheStatus() {
        #expect(CompanionClientError.badResponse(500, "").errorDescription == "HTTP 500")
    }

    @Test func runStepDetailRendersEveryJSONShape() throws {
        #expect(try decode(JSONValueBox.self, #""nine episodes""#).description == "nine episodes")
        #expect(try decode(JSONValueBox.self, "12").description == "12")
        #expect(try decode(JSONValueBox.self, "true").description == "yes")
        #expect(try decode(JSONValueBox.self, "false").description == "no")
        #expect(
            try decode(JSONValueBox.self, #"{"claims":3,"chunks":18}"#).description
                == "chunks 18, claims 3")
        #expect(
            try decode(JSONValueBox.self, #"{"source":"github"}"#).description == "source github")
    }

    @Test func theDefaultTimeoutSurvivesAColdStartingBackend() {
        #expect(CompanionClient.defaultTimeout >= 20)
        #expect(CompanionClient.longRequestTimeout > CompanionClient.defaultTimeout)
    }

    @Test func healthDecodesSeverityAndSeparatesBlockingFromOptional() throws {
        let health = try decode(
            CompanionHealth.self,
            """
            {"ok":true,"degraded":true,"checks":[
              {"name":"postgres","ok":true,"severity":"blocker","detail":"connected"},
              {"name":"reranker","ok":false,"severity":"optional","detail":"not configured"},
              {"name":"stt","ok":false,"severity":"degraded","detail":"unreachable"}
            ]}
            """)
        #expect(health.ok)
        #expect(health.degraded == true)
        #expect(health.failing.map(\.name) == ["reranker", "stt"])
        #expect(health.blocking.isEmpty)
    }

    @Test func aFailingBlockerIsReportedAsBlocking() throws {
        let health = try decode(
            CompanionHealth.self,
            """
            {"ok":false,"degraded":true,"checks":[
              {"name":"reasoning","ok":false,"severity":"blocker","detail":"no provider"}
            ]}
            """)
        #expect(!health.ok)
        #expect(health.blocking.map(\.name) == ["reasoning"])
    }

    @Test func aBackendWithoutSeverityStillDecodes() throws {
        let health = try decode(
            CompanionHealth.self,
            #"{"ok":true,"checks":[{"name":"postgres","ok":true,"detail":"connected"}]}"#)
        #expect(health.degraded == nil)
        #expect(health.checks[0].severityKind == .blocker)
    }

    @Test func anUnknownSeverityIsTreatedAsBlockingRatherThanIgnored() throws {
        let check = try decode(
            CompanionCheck.self,
            #"{"name":"future","ok":false,"severity":"catastrophic","detail":"x"}"#)
        #expect(check.severityKind == .blocker)
    }
}
