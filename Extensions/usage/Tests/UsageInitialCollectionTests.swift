import AppKit
import EdithExtensionUI
import SwiftUI
import EdithExtensionSupport
import Foundation
import Testing

@testable import UsageExtension

@MainActor @Suite(.serialized) struct UsageInitialCollectionTests {
    @Test func initialDashboardStaysLoadingUntilItsFirstDocumentIsReady() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (events, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let data = try document()
        let controller = UsageWorkerController(
            dataDirectory: root, allowsBackgroundCollection: { true },
            collect: { _, _ in
                for await _ in events { break }
                try Task.checkCancellation()
                return data
            })
        let service = UsageUICommands(controller: controller, directory: root)
        var requested = false
        let client = UsageUIClient(invoke: { operation, payload in
            if operation == "usage.ui.document" { requested = true }
            return try await service.execute(operation, payload: payload)
        })
        let model = DashboardModel(uiClient: client)
        let read = Task { await model.load() }
        while !requested { await Task.yield() }
        #expect(model.contentLoad.state == .loading)
        #expect(model.contentLoad.errorMessage == nil)
        try await capture(model, name: "initial-collection")
        release.yield()
        await read.value
        await model.awaitPendingComputation()
        #expect(model.loaded)
        #expect(model.contentLoad.errorMessage == nil)
        try await capture(model, name: "collection-ready")
        model.shutdown()
        await client.stopAndWait()
        await service.shutdownAndWait()
        await controller.shutdown()
    }

    @Test func firstDocumentWaitsForCollectionInsteadOfReportingADisabledExtension() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (events, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let data = try document()
        let controller = UsageWorkerController(
            dataDirectory: root, allowsBackgroundCollection: { true },
            collect: { _, _ in
                for await _ in events { break }
                try Task.checkCancellation()
                return data
            })
        let service = UsageUICommands(controller: controller, directory: root)
        let pending = try await service.execute("usage.ui.document", payload: Data("{}".utf8))
        #expect(try JSONDecoder().decode([String: Bool].self, from: pending) == ["pending": true])
        let client = UsageUIClient(invoke: { try await service.execute($0, payload: $1) })
        let read = Task { try await client.document() }
        #expect(controller.refreshing)
        release.yield()
        let result = try await read.value
        #expect(result.daily.isEmpty)
        #expect(controller.failure == nil)
        #expect(!controller.refreshing)
        await client.stopAndWait()
        await service.shutdownAndWait()
        await controller.shutdown()
    }

    @Test func pendingDocumentReadCancelsWithoutCancellingTheSharedCollector() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (events, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let data = try document()
        let controller = UsageWorkerController(
            dataDirectory: root, allowsBackgroundCollection: { true },
            collect: { _, _ in
                for await _ in events { break }
                try Task.checkCancellation()
                return data
            })
        let service = UsageUICommands(controller: controller, directory: root)
        var requested = false
        let client = UsageUIClient(invoke: { operation, payload in
            if operation == "usage.ui.document" { requested = true }
            return try await service.execute(operation, payload: payload)
        })
        let read = Task { try await client.document() }
        while !requested { await Task.yield() }
        read.cancel()
        await #expect(throws: CancellationError.self) { try await read.value }
        #expect(controller.refreshing)
        release.yield()
        await controller.waitForRefresh()
        #expect(controller.failure == nil)
        await client.stopAndWait()
        await service.shutdownAndWait()
        await controller.shutdown()
    }

    @Test func failedInitialCollectionReportsTheCollectorFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = UsageWorkerController(dataDirectory: root) { _, _ in
            throw ExtensionPeerError.rejected("Synthetic collector failure.")
        }
        _ = try controller.requestRefresh()
        await controller.waitForRefresh()
        let service = UsageUICommands(controller: controller, directory: root)
        do {
            _ = try await service.execute("usage.ui.document", payload: Data("{}".utf8))
            Issue.record("The failed collector returned a document")
        } catch {
            #expect(error.localizedDescription == "Synthetic collector failure.")
        }
        await service.shutdownAndWait()
        await controller.shutdown()
    }

    private func capture(_ model: DashboardModel, name: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["EDITH_USAGE_EVIDENCE_DIRECTORY"]
        else {
            return
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let host = NSHostingView(
            rootView: DashboardView(model: model)
                .environment(\.automaticViewActionsEnabled, false)
                .environment(\.compactLayout, false)
                .environment(\.colorScheme, .dark)
                .frame(width: 1100, height: 800)
                .background(DashSkin.paper(true)))
        host.sizingOptions = []
        host.frame = .init(x: 0, y: 0, width: 1100, height: 800)
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func document() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 8, "generatedAt": "2026-10-09T12:00:00Z", "sources": [],
            "defaultSources": [], "sourceMeta": [:], "sessions": [], "daily": [],
            "totals": [
                "cost": 0, "tokens": 0, "inputTokens": 0, "outputTokens": 0,
                "cacheCreationTokens": 0, "cacheReadTokens": 0, "bySource": [:],
            ],
        ])
    }
}
