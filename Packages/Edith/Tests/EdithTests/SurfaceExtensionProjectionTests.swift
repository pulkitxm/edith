import Foundation
import Testing

@testable import EdithKit

struct SurfaceExtensionProjectionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func downloadCountsAndActionsFollowTheSelectedKinds() {
        let records = [
            DownloadRecord(
                url: URL(string: "https://example.com/video")!,
                status: .downloading(
                    progress: "42.5% 8 MiB/s ETA 00:14", videoIndex: 1, videoCount: 1),
                outputFilename: nil, createdAt: now, kind: .video),
            DownloadRecord(
                url: URL(string: "https://example.com/audio")!, status: .error("Connection reset"),
                outputFilename: nil, createdAt: now, kind: .audio),
            DownloadRecord(
                url: URL(string: "https://example.com/queued")!, status: .queued,
                outputFilename: nil, createdAt: now, kind: .video),
            DownloadRecord(
                url: URL(string: "https://example.com/done")!, status: .done("sample.m4a"),
                outputFilename: nil, createdAt: now, kind: .audio, resultPaths: ["/tmp/sample.m4a"]),
        ]
        let snapshot = DownloadWorkerSnapshot(
            records: records, logs: [:], enabled: true, running: true, generation: UUID(),
            revision: 1)
        var tile = SurfaceTile(.ability("downloads"))
        let all = SurfaceExtensionProjection.downloads(snapshot, tile: tile)
        #expect(all.rows.first?.id == records[1].id.uuidString)
        #expect(
            all.rows.first?.actions == [
                .init("Retry", "arrow.clockwise", .retryDownload(records[1].id))
            ])
        #expect(all.rows.first { $0.id == records[0].id.uuidString }?.progress == 0.425)
        #expect(
            all.rows.first { $0.id == records[3].id.uuidString }?.actions.first?.action
                == .reveal(URL(fileURLWithPath: "/tmp/sample.m4a")))
        tile.sourceIDs = ["video"]
        let selected = SurfaceExtensionProjection.downloads(snapshot, tile: tile)
        #expect(selected.rows.count == 2)
        #expect(selected.metrics.first { $0.id == "failed" }?.value == "0")
        #expect(selected.metrics.first { $0.id == "queued" }?.value == "1")
        tile.sourceIDs = []
        let none = SurfaceExtensionProjection.downloads(snapshot, tile: tile)
        #expect(none.rows.isEmpty && none.metrics.allSatisfy { $0.value == "0" })
        #expect(none.sources.count == DownloadKind.allCases.count)
    }

    @Test func clipboardPinsAndContentTypesRemainIndependent() {
        let entries = [
            ClipboardEntry(
                id: "text", sha256: "sample-text", types: ["public.text"], ext: "txt",
                sourceApp: "Notes", sourceBundleID: "sample.notes", createdAt: now, size: 20,
                preview: "A sample note"),
            ClipboardEntry(
                id: "image", sha256: "sample-image", types: ["public.png"], ext: "png",
                sourceApp: "Preview", sourceBundleID: "sample.preview",
                createdAt: now.addingTimeInterval(-100), size: 2048, preview: nil, pinned: true),
        ]
        var tile = SurfaceTile(.ability("clipboard"))
        let all = SurfaceExtensionProjection.clipboard(entries, tile: tile, now: now)
        #expect(all.rows.first?.id == "image")
        #expect(all.rows.first?.actions.last?.action == .pinClipboard("image", false))
        tile.sourceIDs = ["text"]
        let text = SurfaceExtensionProjection.clipboard(entries, tile: tile, now: now)
        #expect(text.rows.map(\.id) == ["text"])
        #expect(text.metrics.first { $0.id == "pinned" }?.value == "0")
        #expect(text.rows.first?.actions.first?.action == .copyClipboard("text"))
    }

    @Test func reachabilityCountsUseExactMachineIdentities() {
        let snapshot = MachineHealthSnapshot(
            checkedAt: now,
            machines: [
                .init(id: "local", name: "Workstation", reachable: true, detail: nil),
                .init(
                    id: "remote", name: "Build host", reachable: false,
                    detail: "Connection unavailable"),
            ], skipped: false)
        var tile = SurfaceTile(.machines)
        tile.sourceIDs = ["remote"]
        let selected = SurfaceExtensionProjection.machines(snapshot, tile: tile)
        #expect(selected.rows.map(\.id) == ["remote"])
        #expect(selected.metrics.first { $0.id == "offline" }?.value == "1")
        #expect(selected.metrics.first { $0.id == "online" }?.value == "0")
        #expect(selected.sources.count == 2)
        let disabled = SurfaceExtensionProjection.machines(
            .init(checkedAt: now, machines: snapshot.machines, skipped: true), tile: tile)
        #expect(disabled.message == "Reachability monitoring is off.")
        #expect(disabled.rows.first?.value == "Unknown")
        #expect(disabled.metrics.first { $0.id == "offline" } == nil)
    }

    @Test func displayNumbersRejectNonfiniteValuesAndClampProgress() {
        #expect(SurfaceMetric("cpu", "CPU", "Unknown", fraction: .nan).fraction == nil)
        #expect(SurfaceDataRow("a", title: "a", progress: .infinity).progress == nil)
        #expect(SurfaceMetric("cpu", "CPU", "High", fraction: 4).fraction == 1)
        #expect(SurfaceExtensionProjection.percentage("150%") == 1)
        #expect(SurfaceExtensionProjection.percentage("-5%") == 0)
        #expect(SurfaceExtensionProjection.percentage("no progress") == nil)
        #expect(SurfaceExtensionProjection.duration(.infinity) == "Unavailable")
        #expect(SurfaceExtensionProjection.duration(-20) == "0m")
        #expect(SurfaceExtensionProjection.duration(3660) == "1h 1m")
    }

    @Test func everyDataCardExposesFieldChoicesWithoutDuplicateIdentifiers() {
        for widget in SurfaceWidget.allCases where widget.usesExtensionCard {
            #expect(!widget.fields.isEmpty)
            #expect(Set(widget.fields.map(\.0)).count == widget.fields.count)
            #expect(Set(widget.sourceChoices.map(\.id)).count == widget.sourceChoices.count)
        }
    }
}
