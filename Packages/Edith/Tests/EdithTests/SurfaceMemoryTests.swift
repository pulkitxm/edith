import Foundation
import Testing

@testable import EdithKit

@Suite struct SurfaceMemoryTests {
    private let now = SurfaceSampleData.date
    private var health: CompanionHealthSnapshot {
        .init(
            checkedAt: now, endpoint: "", reachable: true, degraded: false,
            checks: [.init(name: "Index", ok: true, detail: "Ready")], failure: nil, skipped: false)
    }
    private var status: CompanionStatus {
        .init(
            sources: 4, episodes: 120, claims: 30, observations: 60,
            chunks: 240, pendingEpisodes: 2, latestIngestedAt: nil)
    }
    private func episode(_ id: String, kind: String = "note", date: String = "2026-10-09T09:00:00Z")
        -> CompanionEpisode
    {
        .init(id: id, occurredAt: date, kind: kind, title: "Sample item", sha256: "")
    }
    @Test func unavailableAndHealthOnlyWidgetsNeverReadTheLibrary() async throws {
        let client = SurfaceMemoryClient(endpoint: URL(string: "https://sample.invalid")!) { _ in
            Issue.record("An unavailable or excluded library was read.")
            throw SurfaceMemoryReadError.unreadable
        }
        var tile = SurfaceTile(.ability("companion"))
        let absent = try await client.snapshot(.unconfigured(at: now), tile: tile)
        #expect(absent.metrics.first?.value == "Not set up")
        #expect(!absent.metrics.contains { $0.id == "episodes" })
        tile.contentKinds = ["health"]
        let available = try await client.snapshot(health, tile: tile)
        #expect(available.rows.first?.id == "health:Index")
    }
    @Test func requestsAreBoundedReadOnlyMetadataReads() async throws {
        let statusData = try JSONEncoder().encode(status)
        let episodeData = try JSONEncoder().encode([episode("one")])
        let probe = SurfaceMemoryRequestProbe()
        let client = SurfaceMemoryClient(endpoint: URL(string: "https://sample.invalid")!) {
            request in
            await probe.record(request)
            return request.url?.lastPathComponent == "status" ? statusData : episodeData
        }
        let value = try await client.snapshot(health, tile: SurfaceTile(.ability("companion")))
        #expect(value.metrics.first { $0.id == "episodes" }?.value == "120")
        #expect(value.rows.contains { $0.id == "episode:one" })
        let requests = await probe.requests
        #expect(Set(requests.compactMap { $0.url?.path }) == ["/v1/status", "/v1/episodes"])
        #expect(
            requests.allSatisfy {
                $0.httpMethod == "GET" && $0.timeoutInterval == 8 && !$0.httpShouldHandleCookies
            })
        #expect(
            requests.first { $0.url?.lastPathComponent == "episodes" }?.url?.query == "limit=60")
    }
    @Test func partialFailuresKeepHealthAndSuccessfulLibraryData() async throws {
        let data = try JSONEncoder().encode([episode("one")])
        let client = SurfaceMemoryClient(endpoint: URL(string: "https://sample.invalid")!) {
            request in
            if request.url?.lastPathComponent == "status" {
                throw SurfaceMemoryReadError.badResponse(503)
            }
            return data
        }
        let value = try await client.snapshot(health, tile: SurfaceTile(.ability("companion")))
        #expect(value.metrics.first?.value == "Healthy")
        #expect(value.rows.contains { $0.id == "episode:one" })
        #expect(value.message?.contains("response 503") == true)
        #expect(!value.metrics.contains { $0.id == "episodes" })
    }
    @Test func oversizedAndMalformedMetadataDoNotFabricateEmptyTotals() async throws {
        for data in [
            Data(repeating: 32, count: SurfaceMemoryClient.maximumBytes + 1), Data("{}".utf8),
        ] {
            let client = SurfaceMemoryClient(endpoint: URL(string: "https://sample.invalid")!) {
                _ in data
            }
            let value = try await client.snapshot(health, tile: SurfaceTile(.ability("companion")))
            #expect(value.metrics.count == 1)
            #expect(value.message != nil)
        }
        let client = SurfaceMemoryClient(endpoint: URL(string: "file:///tmp/sample")!) { _ in Data()
        }
        await #expect(throws: SurfaceMemoryReadError.self) {
            try await client.snapshot(health, tile: SurfaceTile(.ability("companion")))
        }
    }
    @Test func cancellationPropagatesInsteadOfBecomingAWidgetError() async {
        let client = SurfaceMemoryClient(endpoint: URL(string: "https://sample.invalid")!) { _ in
            throw CancellationError()
        }
        await #expect(throws: CancellationError.self) {
            try await client.snapshot(health, tile: SurfaceTile(.ability("companion")))
        }
    }
    @Test func recentItemsAreDeduplicatedBoundedAndFilteredWithoutChangingTotals() {
        var tile = SurfaceTile(.ability("companion")); tile.sourceIDs = ["voice", "missing-kind"]
        let items =
            [
                episode("voice", kind: "voice"), episode("voice", kind: "voice"),
                episode("bad-date", date: "invalid"),
            ]
            + (0..<80).map { episode("note-\($0)", date: "2026-10-08T09:00:00Z") }
        let value = SurfaceMemoryProjection.snapshot(
            health, status: status, episodes: items, tile: tile)
        #expect(value.rows.filter { $0.id.hasPrefix("episode:") }.map(\.id) == ["episode:voice"])
        #expect(value.metrics.first { $0.id == "episodes" }?.value == "120")
        #expect(value.sources.contains { $0.id == "missing-kind" })
        #expect(value.message?.contains("whole Memory service") == true)
        tile.sourceIDs = nil; tile.contentKinds = ["recent"]
        let recent = SurfaceMemoryProjection.snapshot(
            health, status: status, episodes: items, tile: tile)
        #expect(recent.rows.count == 60)
        #expect(Set(recent.rows.map(\.id)).count == 60)
        #expect(recent.metrics.isEmpty)
        tile.sourceIDs = []
        #expect(
            SurfaceMemoryProjection.snapshot(health, status: status, episodes: items, tile: tile)
                .rows.isEmpty)
    }
    @Test func samplesHonorTheActualLibraryFilters() {
        var tile = SurfaceTile(.ability("companion")); tile.sourceIDs = ["voice"];
        tile.contentKinds = ["recent", "totals"]
        let value = SurfaceSampleData.snapshot(tile)
        #expect(value.rows.map(\.id) == ["episode:sample-voice"])
        #expect(value.metrics.first { $0.id == "episodes" }?.value == "240")
        #expect(value.sources.count == 3)
        #expect(tile.widget.supportsSourceFilters)
        #expect(tile.widget.contentChoices.count == 3)
    }
}

private actor SurfaceMemoryRequestProbe {
    var requests: [URLRequest] = []
    func record(_ request: URLRequest) { requests.append(request) }
}
