import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import CompanionExtension

@Suite(.serialized) @MainActor struct CompanionScrollBenchmarkTests {
    static let enabled = ProcessInfo.processInfo.environment["EDITH_SCROLL_BENCHMARK"] != nil
    static let medianBudget = ProcessInfo.processInfo.environment["CI"] == nil ? 12.0 : 1000.0 / 60

    @Test(.enabled(if: enabled)) func scrollingTheLibraryWithSyntheticMemories() async throws {
        let frames = Int(ProcessInfo.processInfo.environment["EDITH_SCROLL_FRAMES"] ?? "") ?? 300
        for count in [60, 3_000] {
            let timing = await Self.measure(count: count, frames: frames)
            print("companion-scroll library-\(count): \(timing) slowAt=\(timing.slowOffsets)")
        }
    }

    @Test(.enabled(if: enabled)) func scrollingTheMindWithSyntheticBeliefs() async throws {
        let frames = Int(ProcessInfo.processInfo.environment["EDITH_SCROLL_FRAMES"] ?? "") ?? 300
        let timing = await Self.measureMind(frames: frames)
        print("companion-scroll mind: \(timing) slowAt=\(timing.slowOffsets)")
    }

    @Test func mindScrollStaysWithinBounds() async throws {
        let timing = await Self.measureMind(frames: 120)
        print("companion-scroll regression mind: \(timing)")
        #expect(Set(timing.offsets).count > 10)
        #expect(timing.worst < 80)
        #expect(timing.median < Self.medianBudget)
    }

    static func measureMind(frames: Int) async -> CompanionScrollTiming {
        let transport = CompanionTransport()
        let stub = CompanionMindStub()
        transport.configureRemote(stub.bridge)
        let model = CompanionMindModel(transport: transport)
        await model.refresh()
        let (window, host) = CompanionScrollHarness.host(
            CompanionMindScreen(model: model, isActive: false)
                .environment(\.companionRequestsEnabled, false)
                .environment(\.compactLayout, false)
                .environment(\.colorScheme, .dark),
            size: CGSize(width: 1_100, height: 800))
        await CompanionScrollHarness.settle(host, for: .seconds(1))
        let timing = await CompanionScrollHarness.scroll(host, frames: frames)
        window.orderOut(nil)
        window.contentView = nil
        await transport.closeAndWait()
        return timing
    }

    @Test func libraryScrollStaysWithinBounds() async throws {
        let timing = await Self.measure(count: 400, frames: 120)
        print("companion-scroll regression library-400: \(timing)")
        #expect(Set(timing.offsets).count > 10)
        #expect(timing.worst < 80)
        #expect(timing.median < Self.medianBudget)
    }

    static func measure(count: Int, frames: Int) async -> CompanionScrollTiming {
        let episodes = CompanionSyntheticMemory.episodes(count)
        let model = CompanionLibraryModel(
            reads: .init(episodes: { episodes }, episode: { _ in throw CancellationError() }))
        await model.refresh()
        let home = CompanionHomeModel()
        let (window, host) = CompanionScrollHarness.host(
            CompanionLibraryScreen(model: model, home: home, isActive: false)
                .environment(\.companionRequestsEnabled, false)
                .environment(\.compactLayout, false)
                .environment(\.colorScheme, .dark),
            size: CGSize(width: 1_100, height: 800))
        await CompanionScrollHarness.settle(host, for: .seconds(1))
        let timing = await CompanionScrollHarness.scroll(host, frames: frames)
        window.orderOut(nil)
        window.contentView = nil
        model.shutdown()
        return timing
    }
}

enum CompanionSyntheticMemory {
    static func episodes(_ count: Int) -> [CompanionEpisode] {
        (0..<count).map { index in
            CompanionEpisode(
                id: "episode-\(index)",
                occurredAt: String(
                    format: "2026-%02d-%02dT09:00:00Z", index % 12 + 1, index % 28 + 1),
                kind: ["note", "voice", "pdf", "chat"][index % 4],
                title: "Synthetic memory \(index) about a sample project and its follow-ups",
                sha256: String(format: "%064x", index))
        }
    }
}

@MainActor final class CompanionMindStub {
    private var uploads: [UUID: Data] = [:]

    var bridge: CompanionUIBridge {
        CompanionUIBridge(invoke: { [self] command, payload in
            switch command {
            case "companion.ui.upload":
                return try JSONEncoder().encode(CompanionJob(id: UUID(), offset: 0))
            case "companion.ui.uploadChunk":
                let chunk = try JSONDecoder().decode(CompanionUploadChunk.self, from: payload)
                uploads[chunk.id, default: Data()].append(chunk.data)
                return Data("{}".utf8)
            case "companion.ui.result":
                let job = try JSONDecoder().decode(CompanionJob.self, from: payload)
                let upload = uploads[job.id] ?? Data()
                let size = upload.prefix(4).reduce(0) { $0 << 8 | Int($1) }
                let head = try JSONDecoder().decode(
                    CompanionHTTPHead.self, from: upload.subdata(in: 4..<(4 + size)))
                return try JSONEncoder().encode(
                    CompanionJobReply(
                        done: true, error: nil, status: 200, contentType: "application/json",
                        data: try body(head.path)))
            default:
                return Data("{}".utf8)
            }
        })
    }

    private func body(_ path: String) throws -> Data {
        let encoder = JSONEncoder()
        switch path {
        case "beliefs":
            return try encoder.encode(
                (0..<30).map {
                    CompanionBelief(
                        id: "belief-\($0)",
                        statement:
                            "Synthetic belief \($0): the sample project tends to slip when the plan is not reviewed weekly",
                        kind: "pattern", confidence: Double($0 % 10) / 10 + 0.05,
                        firstFormed: "2026-03-\(String(format: "%02d", $0 % 28 + 1))T09:00:00Z",
                        evidenceEpisodeIds: ["episode-\($0)"],
                        status: $0 % 7 == 0 ? "superseded" : "active")
                })
        case "claims":
            return try encoder.encode(
                (0..<30).map {
                    CompanionClaim(
                        id: "claim-\($0)",
                        statement: "Synthetic claim \($0) about the sample project",
                        claimType: "fact", testable: true, assertedAt: "2026-04-01T09:00:00Z",
                        episodeId: "episode-\($0)",
                        verdict: [nil, "corroborated", "contradicted", "unclear"][$0 % 4],
                        verdictNote: nil, observationIds: nil)
                })
        case "observations":
            return try encoder.encode(
                (0..<40).map {
                    CompanionObservation(
                        id: "observation-\($0)", source: "github",
                        observedAt: "2026-05-\(String(format: "%02d", $0 % 28 + 1))T09:00:00Z",
                        kind: "pull_request",
                        summary: "Synthetic observed activity number \($0) in a sample repository")
                })
        case "runs":
            return try encoder.encode([
                CompanionRun(
                    id: "run-1", startedAt: "2026-05-01T02:00:00Z",
                    finishedAt: "2026-05-01T02:10:00Z",
                    ok: true, steps: (0..<6).map { CompanionRunStep(name: "step-\($0)", ok: true) })
            ])
        case "core":
            return try encoder.encode(
                ["identity", "values", "goals", "preferences"].map {
                    CompanionCoreSection(
                        section: $0, content: "Synthetic core section about \($0).", tokens: 40,
                        updatedAt: "2026-05-01T02:00:00Z", updatedBy: "nightly")
                })
        case "calibration":
            return try encoder.encode(
                (0..<6).map {
                    CompanionCalibration(
                        domain: "domain-\($0)", direction: "over", samples: 12 + $0,
                        averageMagnitude: 0.1 + Double($0) / 20)
                })
        default:
            return Data("[]".utf8)
        }
    }
}
