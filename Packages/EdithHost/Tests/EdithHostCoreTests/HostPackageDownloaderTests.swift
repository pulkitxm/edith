import ExtensionMarketplace
import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostPackageDownloaderTests {
    @Test func segmentsAreFetchedInParallelAndReassembledExactly() async throws {
        let payload = Data((0..<10_000).map { UInt8($0 % 251) })
        let server = RangeServer(payload: payload)
        let progress = ProgressLog()
        let file = try await server.downloader().download(
            server.url, expectedBytes: Int64(payload.count)
        ) { progress.record($0) }
        defer { try? FileManager.default.removeItem(at: file) }
        let planned = server.downloader().plan(Int64(payload.count))
        #expect(try Data(contentsOf: file) == payload)
        #expect(server.ranges.first == 0..<250)
        #expect(server.ranges.count == planned.count)
        #expect(Set(server.ranges.map { Int64($0.lowerBound) }) == Set(planned.map(\.lowerBound)))
        #expect(progress.last == Int64(payload.count))
    }

    @Test func archivesAreSplitSoEveryConnectionStaysBusyUntilTheEnd() {
        let downloader = HostPackageDownloader()
        for total: Int64 in [40_000, 2_400_000, 12_000_000, 60_000_000] {
            let plan = downloader.plan(total)
            #expect(plan.first == 0..<min(64 * 1024, total))
            #expect(plan.last?.upperBound == total)
            #expect(zip(plan, plan.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
            #expect(plan.dropFirst().allSatisfy { $0.count <= 512 * 1024 })
            if total > 1_000_000 {
                #expect(plan.count > downloader.connections * 2, "\(total)")
            }
        }
        #expect(downloader.plan(2_400_000).dropFirst().allSatisfy { $0.count <= 128 * 1024 })
    }

    @Test func aDroppedConnectionResumesFromTheReceivedOffset() async throws {
        let payload = Data((0..<4_000).map { UInt8($0 % 199) })
        let server = RangeServer(payload: payload, drops: 2)
        let file = try await server.downloader().download(
            server.url, expectedBytes: Int64(payload.count))
        defer { try? FileManager.default.removeItem(at: file) }
        let starts = Set(server.downloader().plan(Int64(payload.count)).map(\.lowerBound))
        #expect(try Data(contentsOf: file) == payload)
        #expect(
            server.ranges.contains { !starts.contains(Int64($0.lowerBound)) }, "\(server.ranges)")
    }

    @Test func aServerWithoutRangeSupportDeliversTheWholeArchiveOnce() async throws {
        let payload = Data((0..<3_500).map { UInt8($0 % 13) })
        let server = RangeServer(payload: payload, ranges: false)
        let file = try await server.downloader().download(
            server.url, expectedBytes: Int64(payload.count))
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try Data(contentsOf: file) == payload)
        #expect(server.ranges.count == 1)
    }

    @Test func rateLimitingIsReportedWithoutRetrying() async throws {
        let server = RangeServer(payload: Data(count: 2_000), status: 429)
        await #expect(throws: MarketplaceError.rateLimited) {
            _ = try await server.downloader().download(server.url, expectedBytes: 2_000)
        }
        #expect(server.ranges.count == 1)
    }

    @Test func aDifferentArchiveSizeIsRejected() async throws {
        let server = RangeServer(payload: Data(count: 2_000))
        await #expect(throws: MarketplaceError.downloadFailed) {
            _ = try await server.downloader().download(server.url, expectedBytes: 2_500)
        }
    }

    @Test func aConnectionThatKeepsFailingGivesUpAfterTheAttemptBudget() async throws {
        let server = RangeServer(payload: Data(count: 2_000), drops: 100, dropsAtStart: true)
        await #expect(throws: URLError.self) {
            _ = try await server.downloader(attempts: 2).download(
                server.url, expectedBytes: 2_000)
        }
        #expect(server.ranges.count == 2)
    }

    @Test func contentRangeHeadersAreParsedStrictly() {
        #expect(HostContentRange("bytes 0-99/1000") != nil)
        #expect(HostContentRange("bytes 100-99/1000") == nil)
        #expect(HostContentRange("bytes 0-1000/1000") == nil)
        #expect(HostContentRange("items 0-9/10") == nil)
    }

    @Test func transferSpeedIsSmoothedOverHalfSecondWindows() {
        let start = ContinuousClock.now
        var sample = HostTransferSample(instant: start, bytes: 0)
        #expect(sample.update(bytes: 100, at: start + .milliseconds(100)) == nil)
        #expect(sample.update(bytes: 1_000, at: start + .seconds(1)) == 1_000)
        #expect(sample.update(bytes: 3_000, at: start + .seconds(2)) == 1_400)
    }

    @Test func operationSummariesNameTheirPhaseAndBytes() {
        #expect(HostExtensionOperation(phase: .queued).summary == "Queued")
        #expect(HostExtensionOperation(phase: .installing).summary == "Installing")
        #expect(HostExtensionOperation(phase: .downloading).summary == "Downloading")
        let downloading = HostExtensionOperation(
            phase: .downloading, receivedBytes: 4_000_000, totalBytes: 12_000_000,
            bytesPerSecond: 320_000)
        #expect(downloading.summary == "Downloading 4 MB of 12 MB · 320 KB/s")
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    var last: Int64? { lock.withLock { values.last } }
    func record(_ value: Int64) { lock.withLock { values.append(value) } }
}

private final class RangeServer: @unchecked Sendable {
    let url: URL
    private let host: String

    init(
        payload: Data, ranges: Bool = true, drops: Int = 0, dropsAtStart: Bool = false,
        status: Int? = nil
    ) {
        host = "archive-\(UUID().uuidString.lowercased()).stub.test"
        url = URL(string: "https://\(host)/package.zip")!
        RangeStub.register(
            host,
            RangeStub.Behavior(
                payload: payload, ranges: ranges, drops: drops, dropsAtStart: dropsAtStart,
                status: status))
    }

    deinit { RangeStub.unregister(host) }

    var ranges: [Range<Int>] { RangeStub.requests(host) }

    func downloader(attempts: Int = 4) -> HostPackageDownloader {
        HostPackageDownloader(
            connections: 4, segmentBytes: 1_000, minimumSegmentBytes: 200, probeBytes: 250,
            attempts: attempts, idleTimeout: 5
        ) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [RangeStub.self]
            return configuration
        }
    }
}

private final class RangeStub: URLProtocol, @unchecked Sendable {
    struct Behavior {
        let payload: Data
        let ranges: Bool
        var drops: Int
        let dropsAtStart: Bool
        let status: Int?
        var requests: [Range<Int>] = []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var behaviors: [String: Behavior] = [:]

    static func register(_ host: String, _ behavior: Behavior) {
        lock.withLock { behaviors[host] = behavior }
    }

    static func unregister(_ host: String) {
        _ = lock.withLock { behaviors.removeValue(forKey: host) }
    }

    static func requests(_ host: String) -> [Range<Int>] {
        lock.withLock { behaviors[host]?.requests ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".stub.test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        let requested = Self.range(request.value(forHTTPHeaderField: "Range"))
        let state: (Behavior, Bool)? = Self.lock.withLock {
            guard var behavior = Self.behaviors[host] else { return nil }
            let total = behavior.payload.count
            behavior.requests.append(
                requested.map { $0.lowerBound..<min($0.upperBound, total) } ?? 0..<total)
            let drop = behavior.drops > 0
            if drop { behavior.drops -= 1 }
            Self.behaviors[host] = behavior
            return (behavior, drop)
        }
        guard let (behavior, drop) = state else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let total = behavior.payload.count
        if let status = behavior.status {
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let body: Data
        let response: HTTPURLResponse
        if behavior.ranges, let requested, requested.lowerBound < total {
            let range = requested.lowerBound..<min(requested.upperBound, total)
            body = behavior.payload.subdata(in: range)
            response = HTTPURLResponse(
                url: url, statusCode: 206, httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(total)",
                    "Content-Type": "application/zip",
                ])!
        } else {
            body = behavior.payload
            response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "\(total)", "Content-Type": "application/zip"])!
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if drop {
            if !behavior.dropsAtStart {
                client?.urlProtocol(self, didLoad: body.prefix(body.count / 2))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) {
                self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
            return
        }
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func range(_ header: String?) -> Range<Int>? {
        guard let header, header.hasPrefix("bytes=") else { return nil }
        let bounds = header.dropFirst(6).split(separator: "-")
        guard bounds.count == 2, let start = Int(bounds[0]), let end = Int(bounds[1]) else {
            return nil
        }
        return start..<(end + 1)
    }
}
