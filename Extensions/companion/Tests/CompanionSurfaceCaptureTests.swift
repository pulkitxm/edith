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
    private var uploads: [UUID: Data] = [:]

    var bridge: CompanionUIBridge {
        CompanionUIBridge(invoke: { [self] command, payload in
            let encoder = JSONEncoder()
            switch command {
            case "companion.ui.backend":
                return try encoder.encode(backend)
            case "companion.ui.setup":
                return try encoder.encode(setup)
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
        default: return Data("[]".utf8)
        }
    }
}

@MainActor private enum CompanionCaptureRig {
    static let regular = CGSize(width: 1_100, height: 760)
    static let compact = CGSize(width: 640, height: 700)
    static let sheet = CGSize(width: 760, height: 560)

    static var directory: URL? {
        ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    static var variants: [(CGSize, Bool, Double)] {
        [
            (regular, false, 1), (regular, true, 1), (compact, false, 1), (compact, true, 1),
            (regular, false, 1.6),
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
