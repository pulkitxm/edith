import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
@Suite(.serialized)
struct StoragePaneTests {
    init() {
        _ = TestWindowHost.application
    }

    @Test func unknownSizesNeverPresentAsKnownSavings() {
        var unknown = StorageBytes()
        unknown.complete = false
        #expect(StorageSizeLine.value(unknown).hasPrefix("Unknown"))
        unknown.exists = true
        #expect(StorageSizeLine.value(unknown).hasPrefix("Partial"))
        #expect(!StorageSizeLine.value(unknown).contains("saved"))
        var known = StorageBytes()
        known.logical = 2048
        known.allocated = 4096
        #expect(StorageSizeLine.value(known) == "2 KB logical · 4 KB allocated")
    }

    @Test func replacementAndCancellationRejectLateScanPublicationWhileRetainingContent()
        async throws
    {
        let fixture = try StorageFixture()
        defer { fixture.clean() }
        let inventory = fixture.inventory()
        let original = try StorageAccounting.scan(scopes: inventory.scopes)
        let model = StoragePaneModel()
        await model.refresh(inventory: inventory)
        let gate = ScanGate()
        let first = Task {
            await model.refresh(inventory: inventory, scan: { _ in await gate.wait() })
        }
        await gate.waitForRequests(1)
        #expect(model.measurement?.total.logical == original.total.logical)
        #expect(model.load.isRefreshing)
        try fixture.file("Edith.app/Contents/MacOS/Edith", count: 18000)
        let latest = try StorageAccounting.scan(scopes: inventory.scopes)
        let second = Task {
            await model.refresh(inventory: inventory, scan: { _ in await gate.wait() })
        }
        await gate.waitForRequests(2)
        await gate.finish(1, measurement: latest)
        await second.value
        await gate.finish(0, measurement: original)
        await first.value
        #expect(model.measurement?.total.logical == latest.total.logical)
        #expect(await gate.cancelled == 1)
        let third = Task {
            await model.refresh(inventory: inventory, scan: { _ in await gate.wait() })
        }
        await gate.waitForRequests(3)
        model.cancelScan()
        await gate.finish(2, measurement: original)
        await third.value
        #expect(model.measurement?.total.logical == latest.total.logical)
        #expect(!model.load.isRunning)
        #expect(await gate.cancelled == 2)
    }

    @Test func storageRendersAtCompactRegularZoomAndBothSchemes() async throws {
        let fixture = try StorageFixture()
        defer { fixture.clean() }
        let model = StoragePaneModel()
        await model.refresh(inventory: fixture.inventory())
        #expect(model.measurement != nil)
        let previousScale = UIScale.current
        defer { UIScale.apply(previousScale) }
        for (name, width, height, zoom, scheme) in [
            ("regular-light", 1100.0, 1000.0, 1.0, ColorScheme.light),
            ("regular-dark", 1100.0, 1000.0, 1.0, ColorScheme.dark),
            ("compact-light", 520.0, 1000.0, 1.0, ColorScheme.light),
            ("compact-dark", 520.0, 1000.0, 1.0, ColorScheme.dark),
            ("zoom-light", 700.0, 1000.0, 1.5, ColorScheme.light),
            ("zoom-dark", 1100.0, 1000.0, 1.5, ColorScheme.dark),
            ("full-light", 1100.0, 2400.0, 1.0, ColorScheme.light),
        ] {
            UIScale.apply(zoom)
            let host = NSHostingView(
                rootView: StoragePane(inventory: { fixture.inventory() }, model: model)
                    .environment(\.compactLayout, width < UIScale.pt(720))
                    .environment(\.colorScheme, scheme)
                    .environment(\.automaticViewActionsEnabled, false)
                    .transaction { $0.animation = nil })
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let window = TestWindowHost.window(contentRect: host.frame)
            window.contentView = host
            window.orderBack(nil)
            defer { window.orderOut(nil) }
            for _ in 0..<8 {
                host.layoutSubtreeIfNeeded()
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(40))
            }
            #expect(host.fittingSize.width.isFinite && host.fittingSize.height.isFinite)
            #expect(abs(host.bounds.width - width) < 1)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
            if let capture = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_STORAGE"] {
                let directory = URL(fileURLWithPath: capture)
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(
                    to: directory.appendingPathComponent(name + ".png"))
            }
            #expect(!TestWindowHost.isExposedOnDesktop(window))
        }
    }

    private actor ScanGate {
        private var continuations: [Int: CheckedContinuation<StorageMeasurement, Never>] = [:]
        private var started = 0
        private(set) var cancelled = 0

        func wait() async -> StorageMeasurement {
            let id = started
            started += 1
            let result = await withCheckedContinuation { continuations[id] = $0 }
            if Task.isCancelled { cancelled += 1 }
            return result
        }

        func waitForRequests(_ count: Int) async {
            while started < count { await Task.yield() }
        }

        func finish(_ id: Int, measurement: StorageMeasurement) {
            continuations.removeValue(forKey: id)?.resume(returning: measurement)
        }
    }
}
