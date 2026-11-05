import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import CompanionExtension

private struct BackendReply: Encodable {
    var hosts: [CompanionHost] = []
    var deployment: CompanionDeployment?
    var services: [CompanionServiceStatus] = []
    var selectedHostID: UUID?
    var config = CompanionStackConfig()
    var probing = false
    var working = false
    var busy: String?
    var error: String?
    var lastLog = ""
    var configStatus: String?
    var configStatusIsError = false
    var secretsStatus: String?
    var secretHints: [CompanionSecretKind: String] = [:]
}

private struct SetupReply: Encodable {
    var step = CompanionSetupStep.welcome
    var hosts: [CompanionHost] = []
    var probing = false
    var selectedHostID: UUID?
    var stages: [CompanionDeployStage: CompanionStageState] = [:]
    var deploying = false
    var deployError: String?
    var deployed: CompanionDeployment?
    var working = false
}

@MainActor private final class CompanionCaptureStub {
    var reachable = true
    var status = CompanionStatus(
        sources: 0, episodes: 0, claims: 0, observations: 0, chunks: 0, pendingEpisodes: 0,
        latestIngestedAt: nil)
    var episodes: [CompanionEpisode] = []
    var backend = BackendReply()
    var setup = SetupReply()
    var holdsRequests = false
    var seedsMind = false
    private var uploads: [UUID: Data] = [:]

    var bridge: CompanionUIBridge {
        CompanionUIBridge(invoke: { [self] command, payload in
            let encoder = JSONEncoder()
            switch command {
            case "companion.ui.backend":
                return try encoder.encode(backend)
            case "companion.ui.setup":
                return try encoder.encode(setup)
            case "companion.ui.capture":
                return try encoder.encode(
                    CompanionCaptureState(CompanionCaptureModel(remote: nil, transport: .shared)))
            case "companion.ui.upload":
                guard reachable else { throw ExtensionPeerError.unavailable }
                if holdsRequests { try await Task.sleep(for: .seconds(60)) }
                return try encoder.encode(CompanionJob(id: UUID(), offset: 0))
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
                return try encoder.encode(
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
        case "health":
            return try encoder.encode(
                CompanionHealth(
                    ok: true,
                    checks: [CompanionCheck(name: "database", ok: true, detail: "answering")]))
        case "status": return try encoder.encode(status)
        case "episodes": return try encoder.encode(episodes)
        default: return try CompanionCaptureMind.body(path, enabled: seedsMind, encoder: encoder)
        }
    }
}

private enum CompanionCaptureMind {
    static let citations = [
        CompanionAskCitation(
            episodeId: "e1", quote: "The launch moved to the second week of March.",
            support: "direct", title: "Launch planning notes", occurredAt: "2026-10-14T09:00:00Z"),
        CompanionAskCitation(
            episodeId: "e2", quote: "Design review is booked for Thursday.", support: "partial",
            title: "Standup with the design team", occurredAt: "2026-10-20T10:30:00Z"),
    ]

    static func body(_ path: String, enabled: Bool, encoder: JSONEncoder) throws -> Data {
        guard enabled else { return Data("[]".utf8) }
        switch path {
        case "beliefs":
            return try encoder.encode([
                CompanionBelief(
                    id: "b1", statement: "You plan releases around design review, not engineering.",
                    kind: "pattern", confidence: 0.82, firstFormed: "2026-09-02T09:00:00Z",
                    evidenceEpisodeIds: ["e1", "e2"], status: "active"),
                CompanionBelief(
                    id: "b2", statement: "You prefer async updates over standups.",
                    kind: "preference", confidence: 0.64, firstFormed: "2026-08-18T09:00:00Z",
                    evidenceEpisodeIds: ["e2"], status: "superseded"),
            ])
        case "claims":
            return try encoder.encode([
                CompanionClaim(
                    id: "c1", statement: "The launch moved to the second week of March.",
                    claimType: "fact", testable: true, assertedAt: "2026-10-14T09:00:00Z",
                    episodeId: "e1", verdict: "corroborated", verdictNote: "Matches the calendar.",
                    observationIds: ["o1"]),
                CompanionClaim(
                    id: "c2", statement: "The billing migration finishes this week.",
                    claimType: "commitment", testable: true, assertedAt: "2026-10-22T09:00:00Z",
                    episodeId: nil, verdict: nil, verdictNote: nil, observationIds: nil),
            ])
        case "observations":
            return try encoder.encode([
                CompanionObservation(
                    id: "o1", source: "calendar", observedAt: "2026-10-14T09:00:00Z",
                    kind: "event", summary: "Launch review moved to March 11."),
                CompanionObservation(
                    id: "o2", source: "github", observedAt: "2026-10-21T17:00:00Z", kind: "commit",
                    summary: "Merged 4 pull requests in the billing repository."),
            ])
        case "runs":
            return try encoder.encode([
                CompanionRun(
                    id: "r1", startedAt: "2026-11-04T02:00:00Z",
                    finishedAt: "2026-11-04T02:04:00Z", ok: true, steps: [])
            ])
        case "core":
            return try encoder.encode([
                CompanionCoreSection(
                    section: "persona", content: "Founder building a macOS app.", tokens: 12,
                    updatedAt: "2026-11-01T09:00:00Z", updatedBy: "you")
            ])
        case "calibration":
            return try encoder.encode([
                CompanionCalibration(
                    domain: "timelines", direction: "optimistic", samples: 14,
                    averageMagnitude: 0.28),
                CompanionCalibration(
                    domain: "estimates", direction: "accurate", samples: 9, averageMagnitude: 0.04),
            ])
        case "hypotheses":
            return try encoder.encode([
                CompanionHypothesis(
                    id: "h1", statement: "Launch dates slip when design review moves.",
                    mechanism: "Review sets the final scope.", status: "testing", prior: 0.5,
                    posterior: 0.71, testCount: 3, alternativeExplanations: [],
                    formedAt: "2026-10-01T09:00:00Z", generatedBy: "nightly")
            ])
        case "predictions":
            return try encoder.encode([
                CompanionPrediction(
                    id: "p1", hypothesisId: "h1", statement: "The launch date moves again.",
                    observable: "Calendar change before March 1.",
                    windowStart: "2026-11-01T00:00:00Z", windowEnd: "2027-03-01T00:00:00Z",
                    resolvedAt: nil, outcome: nil)
            ])
        case "discrepancies":
            return try encoder.encode([
                CompanionDiscrepancy(
                    id: "d1", claim: "You said the migration would finish on Friday.",
                    kind: "timeline", magnitude: 0.6, detectedAt: "2026-10-30T09:00:00Z",
                    dismissed: false, userResponse: nil)
            ])
        case "questions":
            return try encoder.encode(
                CompanionQuestionList(
                    questions: [], muted: ["health"], askedToday: 1, dailyBudget: 3))
        case "settings/reason":
            return try encoder.encode(
                CompanionReasonSettings(
                    provider: "anthropic", url: "https://api.example.invalid",
                    model: "reason-large",
                    hasApiKey: true, apiKeyHint: "…7f2a", configured: true,
                    description: "Hosted reasoning model"))
        case "settings/connectors":
            return try encoder.encode(
                CompanionConnectorSettings(
                    github: CompanionConnectorState(configured: true, detail: "2 repositories"),
                    notion: CompanionConnectorState(configured: false, detail: "Not connected"),
                    sources: ["calendar", "github"], importable: ["chatgpt"]))
        case "conversations":
            return try encoder.encode([
                CompanionConversation(
                    id: "t1", title: "When is the launch?", createdAt: "2026-11-02T09:00:00Z",
                    lastActiveAt: "2026-11-02T09:05:00Z", messageCount: 2,
                    lastMessage: "The launch moved to the second week of March."),
                CompanionConversation(
                    id: "t2", title: "Billing migration status",
                    createdAt: "2026-10-29T09:00:00Z", lastActiveAt: "2026-10-29T09:10:00Z",
                    messageCount: 4, lastMessage: "Four pull requests are merged."),
            ])
        case "conversations/t1":
            return try encoder.encode(
                CompanionConversationDetail(
                    id: "t1", title: "When is the launch?", createdAt: "2026-11-02T09:00:00Z",
                    messages: [
                        CompanionMessage(
                            id: "m1", role: "user",
                            content: "When is the launch, and what could move it?",
                            citations: nil, model: nil, latencyMs: nil,
                            createdAt: "2026-11-02T09:00:00Z"),
                        CompanionMessage(
                            id: "m2", role: "assistant",
                            content:
                                "The launch moved to the **second week of March** [1].\n\nTwo things could move it again:\n\n- Design review, booked for Thursday [2]\n- The billing migration, which is not finished yet",
                            citations: citations, model: "reason-large", latencyMs: 2_140,
                            createdAt: "2026-11-02T09:00:04Z"),
                    ]))
        default:
            return Data("[]".utf8)
        }
    }
}

@MainActor private enum CompanionCaptureRig {
    static let regular = CGSize(width: 1_100, height: 760)
    static let wide = CGSize(width: 1_600, height: 900)
    static let tall = CGSize(width: 1_600, height: 1_500)
    static let compact = CGSize(width: 640, height: 700)
    static let sheet = CGSize(width: 760, height: 560)

    static var directory: URL? {
        ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    static var variants: [(CGSize, Bool, Double)] {
        [
            (regular, false, 1), (regular, true, 1), (wide, false, 1), (tall, false, 1),
            (compact, false, 1),
            (compact, true, 1), (regular, false, 1.6),
        ]
    }

    @discardableResult
    static func capture<V: View>(
        _ name: String, size: CGSize, dark: Bool, zoom: Double = 1, settle: Int = 12,
        @ViewBuilder _ view: () -> V
    ) async throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let prior = UIScale.current
        UIScale.apply(zoom)
        defer { UIScale.apply(prior) }
        let host = NSHostingView(
            rootView:
                NavigationRouteHost(router: WindowRouter()) {
                    view()
                        .environment(\.compactLayout, size.width < UIScale.pt(720))
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .environment(\.controlActiveState, .key)
                        .environment(\.windowVisible, true)
                })
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<settle {
            try await Task.sleep(for: .milliseconds(60))
            host.layoutSubtreeIfNeeded()
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        window.contentView = nil
        window.close()
        if let directory {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            let suffix = "\(Int(size.width))x\(Int(size.height))-\(dark ? "dark" : "light")"
            let zoomSuffix = zoom == 1 ? "" : "-zoom\(zoom)"
            try data.write(
                to: directory.appendingPathComponent("memory-\(name)-\(suffix)\(zoomSuffix).png"))
        }
        return bitmap
    }

    static func distinctColors(_ bitmap: NSBitmapImageRep) -> Int {
        var colors = Set<Int>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 7) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 7) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                colors.insert(
                    Int(color.redComponent * 31) << 10 | Int(color.greenComponent * 31) << 5
                        | Int(color.blueComponent * 31))
            }
        }
        return colors.count
    }
}

@Suite(.serialized) @MainActor struct CompanionSurfaceCaptureTests {
    private static let isolated =
        ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil

    private static var readyFacts: CompanionHostFacts {
        CompanionHostFacts(
            os: "linux", arch: "arm64", cpuCores: 8, memoryMb: 32_768, diskFreeMb: 240_000,
            gpuModel: nil,
            runtimes: [
                CompanionRuntimeStatus(
                    kind: .docker, version: "27.1", daemonRunning: true, composeVersion: "2.29")
            ],
            portsTaken: [])
    }

    private static var hosts: [CompanionHost] {
        [
            CompanionHost(
                id: CompanionHost.localID, name: "This Mac", target: "local", isLocal: true,
                reachable: true,
                facts: CompanionHostFacts(
                    os: "darwin", arch: "arm64", cpuCores: 8, memoryMb: 16_384, diskFreeMb: 4_000,
                    gpuModel: nil, runtimes: [], portsTaken: [])),
            CompanionHost(
                id: UUID(uuidString: "00000000-0000-4000-8000-0000000000C1")!, name: "build-server",
                target: "deploy@build.example.invalid", isLocal: false, reachable: true,
                facts: readyFacts),
        ]
    }

    private func page(
        tab: CompanionTab, stub: CompanionCaptureStub, name: String
    ) async throws {
        SharedDefaults.store.set(tab.rawValue, forKey: AppStorageKeys.Companion.tab)
        SharedDefaults.store.set(true, forKey: AppStorageKeys.Companion.setupDeclined)
        for (size, dark, zoom) in CompanionCaptureRig.variants {
            let session = CompanionWorkspaceSession(remote: stub.bridge)
            let bitmap = try await CompanionCaptureRig.capture(
                name, size: size, dark: dark, zoom: zoom
            ) {
                CompanionPage(session: session)
            }
            #expect(CompanionCaptureRig.distinctColors(bitmap) > 6)
            await session.cancelAndWait()
        }
    }

    @Test func firstRunExplainsMemoryAndOffersSetup() async throws {
        guard Self.isolated else {
            Issue.record("Capture requires an isolated synthetic fixture."); return
        }
        let stub = CompanionCaptureStub()
        stub.reachable = false
        try await page(tab: .chat, stub: stub, name: "first-run")
        #expect(SharedDefaults.store.string(forKey: AppStorageKeys.Companion.tab) == "chat")
    }

    @Test func loadingKeepsThePageShapeWhileWaiting() async throws {
        guard Self.isolated else {
            Issue.record("Capture requires an isolated synthetic fixture."); return
        }
        let stub = CompanionCaptureStub()
        stub.holdsRequests = true
        try await page(tab: .library, stub: stub, name: "library-loading")
    }

    @Test func aDownBackendOffersRecovery() async throws {
        guard Self.isolated else {
            Issue.record("Capture requires an isolated synthetic fixture."); return
        }
        for (size, dark, zoom) in CompanionCaptureRig.variants {
            try await CompanionCaptureRig.capture(
                "not-running", size: size, dark: dark, zoom: zoom
            ) {
                CompanionBackendGateView(
                    gate: .notRunning, setUp: {}, openBackend: {}, retry: {}
                )
                .background(DashSkin.paper(dark))
            }
        }
    }

    @Test func emptyMemoryPointsToTheFirstNote() async throws {
        guard Self.isolated else {
            Issue.record("Capture requires an isolated synthetic fixture."); return
        }
        let stub = CompanionCaptureStub()
        try await page(tab: .chat, stub: stub, name: "chat-empty")
        try await page(tab: .library, stub: stub, name: "library-empty")
    }

    @Test func populatedMemoryGreetsAndLists() async throws {
        guard Self.isolated else {
            Issue.record("Capture requires an isolated synthetic fixture."); return
        }
        let stub = CompanionCaptureStub()
        stub.status = CompanionStatus(
            sources: 2, episodes: 12, claims: 6, observations: 40, chunks: 180, pendingEpisodes: 0,
            latestIngestedAt: "2026-11-01T09:00:00Z")
        stub.episodes = CompanionSyntheticMemory.episodes(12)
        try await page(tab: .chat, stub: stub, name: "chat-populated")
        try await page(tab: .library, stub: stub, name: "library-populated")
    }

    @Test func backendListsWhereMemoryCanRun() async throws {
        guard Self.isolated else {
            Issue.record("Capture requires an isolated synthetic fixture."); return
        }
        let stub = CompanionCaptureStub()
        stub.backend.hosts = Self.hosts
        stub.backend.selectedHostID = Self.hosts[1].id
        try await page(tab: .setup, stub: stub, name: "backend")
    }

    private var seededStub: CompanionCaptureStub {
        let stub = CompanionCaptureStub()
        stub.seedsMind = true
        stub.status = CompanionStatus(
            sources: 2, episodes: 12, claims: 6, observations: 40, chunks: 180, pendingEpisodes: 0,
            latestIngestedAt: "2026-11-01T09:00:00Z")
        stub.episodes = CompanionSyntheticMemory.episodes(12)
        stub.backend.hosts = Self.hosts
        stub.backend.selectedHostID = Self.hosts[1].id
        return stub
    }

    @Test(arguments: [CompanionTab.capture, .desk, .mind, .settings])
    func everyPopulatedMemoryTabFits(_ tab: CompanionTab) async throws {
        guard Self.isolated else {
            Issue.record("Capture requires an isolated synthetic fixture."); return
        }
        try await page(tab: tab, stub: seededStub, name: "\(tab.rawValue)-populated")
    }

    @Test func aChatTranscriptShowsCitationsAndTheNextQuestion() async throws {
        guard Self.isolated else {
            Issue.record("Capture requires an isolated synthetic fixture."); return
        }
        let stub = seededStub
        SharedDefaults.store.set(CompanionTab.chat.rawValue, forKey: AppStorageKeys.Companion.tab)
        SharedDefaults.store.set(true, forKey: AppStorageKeys.Companion.setupDeclined)
        for (size, dark, zoom) in CompanionCaptureRig.variants {
            let session = CompanionWorkspaceSession(remote: stub.bridge)
            await session.chat.open("t1")
            #expect(session.chat.messages.count == 2)
            #expect(session.chat.messages.last?.citations.count == 2)
            let bitmap = try await CompanionCaptureRig.capture(
                "chat-transcript", size: size, dark: dark, zoom: zoom
            ) {
                CompanionPage(session: session)
            }
            #expect(CompanionCaptureRig.distinctColors(bitmap) > 6)
            await session.cancelAndWait()
        }
    }

    @Test func setupWalksThroughEveryStep() async throws {
        guard Self.isolated else {
            Issue.record("Capture requires an isolated synthetic fixture."); return
        }
        let stub = CompanionCaptureStub()
        stub.setup.hosts = Self.hosts
        stub.setup.selectedHostID = Self.hosts[1].id
        stub.setup.stages = [.prepare: .done("ok"), .source: .running("Copying the stack")]
        let deployed = CompanionDeployment(
            machineID: Self.hosts[1].id, machineName: "build-server", tier: "standard")
        let session = CompanionWorkspaceSession(remote: stub.bridge)
        for step in CompanionSetupStep.allCases {
            stub.setup.deploying = step == .deploy
            stub.setup.deployed = step == .deploy ? nil : deployed
            for (dark, zoom) in [(false, 1.0), (true, 1.0), (false, 1.6)] {
                let model = CompanionSetupModel(remote: stub.bridge) { _ in }
                model.step = step
                let size = CGSize(
                    width: CompanionCaptureRig.sheet.width * zoom,
                    height: CompanionCaptureRig.sheet.height * zoom)
                let bitmap = try await CompanionCaptureRig.capture(
                    "setup-\(step.rawValue)", size: size, dark: dark, zoom: zoom
                ) {
                    CompanionSetupSheet(model: model, home: session.home)
                }
                #expect(CompanionCaptureRig.distinctColors(bitmap) > 6)
                await model.cancelAndWait()
            }
        }
        await session.cancelAndWait()
    }
}
