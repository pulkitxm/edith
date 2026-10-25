import Foundation
import Testing

@testable import CompanionExtension

@Suite struct CompanionUploadFramingTests {
    @Test func framedUploadRoundTripsALargeBodyWithoutTheOldCap() throws {
        let body = Data(repeating: 7, count: 80 * 1_024 * 1_024)
        let call = CompanionHTTPCall(
            path: "ingest/video", method: "POST", query: ["name": "clip"],
            contentType: "application/octet-stream", timeout: 600, body: body)
        let parts = try CompanionHTTPHead(call).frame(body: call.body)
        let upload = parts.reduce(into: Data()) { $0.append($1) }
        #expect(upload.count <= CompanionUIEngine.maximumTransferBytes)
        let decoded = try CompanionHTTPHead.decode(upload)
        #expect(decoded.path == call.path && decoded.query == call.query)
        #expect(decoded.body == body)
        try CompanionUIEngine.checked(decoded)
    }

    @Test func aTruncatedBodyIsRejected() throws {
        let call = CompanionHTTPCall(
            path: "ingest", method: "POST", query: [:], contentType: nil, timeout: 30,
            body: Data(repeating: 1, count: 1_000))
        var upload = try CompanionHTTPHead(call).frame(body: call.body).reduce(into: Data()) {
            $0.append($1)
        }
        upload.removeLast()
        #expect(throws: (any Error).self) { try CompanionHTTPHead.decode(upload) }
    }
}
