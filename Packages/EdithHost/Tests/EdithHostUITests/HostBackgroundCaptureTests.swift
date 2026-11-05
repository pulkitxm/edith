import AppKit
import EdithExtensionUI
import EdithHostCore
import SwiftUI
import Testing

@testable import EdithHost

@MainActor @Suite(.serialized) struct HostBackgroundCaptureTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Variant {
        let name: String
        let width: CGFloat
        let height: CGFloat
        let zoom: Double
        let scheme: ColorScheme
        init(
            _ name: String, _ width: CGFloat, _ height: CGFloat, _ zoom: Double = 1,
            _ scheme: ColorScheme = .light
        ) {
            self.name = name; self.width = width; self.height = height
            self.zoom = zoom; self.scheme = scheme
        }
    }

    private enum Scenario: String, CaseIterable {
        case populated, empty, loading, error
    }

    private static let variants = [
        Variant("regular-light", 1100, 760), Variant("regular-dark", 1100, 760, 1, .dark),
        Variant("compact-light", 640, 700), Variant("compact-dark", 640, 700, 1, .dark),
        Variant("zoomed", 1100, 760, 1.6, .dark), Variant("wide", 1600, 960),
    ]

    private func job(
        _ id: String, title: String, phase: String = "idle", ambient: Double? = 900,
        power: String = "any", ability: String? = nil, subscribers: Int = 0,
        lastRun: TimeInterval? = 240, error: String? = nil
    ) throws -> HostBackgroundJob {
        let payload: [String: Any] = [
            "descriptor": [
                "id": id, "title": title, "trigger": "timer", "topic": NSNull(),
                "cadence": ["ambient": ambient.map { $0 as Any } ?? NSNull(), "live": NSNull()],
                "power": power, "abilityID": ability.map { $0 as Any } ?? NSNull(),
            ],
            "phase": phase, "subscribers": subscribers,
            "lastRun": lastRun.map {
                Self.now.addingTimeInterval(-$0).timeIntervalSinceReferenceDate as Any
            }
                ?? NSNull(),
            "lastDuration": 1, "lastError": error.map { $0 as Any } ?? NSNull(), "runCount": 3,
        ]
        return try JSONDecoder().decode(
            HostBackgroundJob.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    private func populatedJobs() throws -> [HostBackgroundJob] {
        [
            try job(
                "usage.refresh", title: "Refresh usage", ambient: 900, power: "pauseOnBattery",
                subscribers: 1, lastRun: 240),
            try job("usage.rollup", title: "Daily summary", ambient: 86_400, lastRun: 7_200),
            try job(
                "sessions.discover", title: "Find coding agent sessions", phase: "running",
                ambient: 60, ability: "herdr", lastRun: 30),
            try job(
                "backup.sync", title: "iCloud backup", phase: "failed", ambient: 86_400,
                power: "pauseOnBattery", lastRun: 3_600,
                error: "iCloud Drive is not available. Sign in to iCloud and try again."),
            try job("storage.inspect", title: "Storage inspection", ambient: nil, lastRun: nil),
        ]
    }

    private func tasks() -> [HostBackgroundTask] {
        HostBackgroundTask.ordered([
            .init(
                id: UUID(), title: "Download Llama weights", activity: "Downloaded 1.2 GB of 4 GB",
                state: .running, operation: "command.run",
                submitted: Self.now.addingTimeInterval(-300),
                started: Self.now.addingTimeInterval(-290), finished: nil, failure: nil),
            .init(
                id: UUID(), title: "Inspecting storage and backup sizes", activity: nil,
                state: .finished, operation: nil, submitted: Self.now.addingTimeInterval(-5_400),
                started: Self.now.addingTimeInterval(-5_400),
                finished: Self.now.addingTimeInterval(-5_380), failure: nil),
            .init(
                id: UUID(), title: "Backing up settings", activity: nil, state: .failed,
                operation: nil, submitted: Self.now.addingTimeInterval(-90_000),
                started: Self.now.addingTimeInterval(-90_000),
                finished: Self.now.addingTimeInterval(-89_990),
                failure: "Settings backup could not finish."),
        ])
    }

    private func status(_ scenario: Scenario) -> HostBackgroundStatus {
        switch scenario {
        case .populated:
            HostBackgroundStatus(
                phase: .running, startedAt: Self.now.addingTimeInterval(-11_000),
                residentBytes: 48_234_496, cpuPercent: 0.4, build: "1.0.0", processIdentifier: 4242,
                schemaVersion: 1, tasks: tasks())
        case .empty:
            HostBackgroundStatus(
                phase: .running, startedAt: Self.now.addingTimeInterval(-42),
                residentBytes: 31_457_280, cpuPercent: 0.1, build: "1.0.0", processIdentifier: 4242,
                schemaVersion: 1)
        case .loading:
            HostBackgroundStatus(phase: .starting)
        case .error:
            HostBackgroundStatus(
                phase: .failed, registration: .awaitingApproval,
                failure: "The background service could not start. Try restarting it.")
        }
    }

    private func jobsModel(_ scenario: Scenario) async throws -> HostBackgroundModel {
        let jobs = scenario == .populated ? try populatedJobs() : []
        let model = HostBackgroundModel(
            environment: .init(
                identity: { scenario == .error ? nil : "core:4242" },
                read: { .init(jobs: jobs, events: [], unavailable: nil) },
                control: { _, _ in }))
        if scenario != .loading { await model.refresh() }
        return model
    }

    private func policyModel(_ scenario: Scenario) async throws -> HostBackgroundPolicyModel {
        let core = try JSONDecoder().decode(
            HostCoreBackgroundPolicy.self,
            from: JSONSerialization.data(
                withJSONObject: ["processIdentifier": 4242, "pauseAmbientOnBattery": true]))
        let result = HostBackgroundPolicyResult(
            core: core,
            propagation: .init(generation: UUID(), pauseAmbientOnBattery: true, owners: []))
        let model = HostBackgroundPolicyModel(
            environment: .init(
                owner: {
                    scenario == .error || scenario == .loading
                        ? nil
                        : HostBackgroundPolicyOwner(identity: "core:4242", processIdentifier: 4242)
                },
                read: { result }, set: { _ in result }))
        if scenario != .loading { await model.refresh() }
        return model
    }

    private func settle(_ window: NSWindow, host: NSView) async {
        for _ in 0..<8 {
            window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    private func capture(_ host: NSView, name: String) throws -> NSBitmapImageRep {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let path = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        }
        return bitmap
    }

    private func distinctColors(_ bitmap: NSBitmapImageRep) -> Int {
        var colors = Set<String>()
        let step = max(1, bitmap.pixelsWide / 40)
        for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                colors.insert(
                    String(
                        format: "%.2f-%.2f-%.2f", color.redComponent, color.greenComponent,
                        color.blueComponent))
            }
        }
        return colors.count
    }

    @Test func backgroundPageRendersEveryStateAtEverySize() async throws {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        var opened: [String] = []
        for scenario in Scenario.allCases {
            let model = try await jobsModel(scenario)
            let policy = try await policyModel(scenario)
            switch scenario {
            case .populated:
                #expect(model.jobs.count == 5)
                #expect(
                    model.groups(titles: { $0 == "usage" ? "Usage" : $0 == "herdr" ? "Herdr" : nil }
                    )
                    .map(\.title) == ["Herdr", "Usage", "Built into Edith"])
                #expect(policy.value == true)
            case .empty:
                #expect(model.jobs.isEmpty && model.failure == nil && !model.load.isRunning)
            case .loading:
                #expect(model.load.state == .loading && policy.value == nil)
            case .error:
                #expect(model.unavailable == "The background service is offline.")
                #expect(policy.failure == "The background service is offline.")
            }
            let variants =
                scenario == .populated
                ? Self.variants + [Variant("full", 1100, 1500)] : Self.variants
            for variant in variants {
                UIScale.apply(variant.zoom)
                let host = NSHostingView(
                    rootView: HostSettingsContainer(category: .constant("agent")) {
                        HostBackgroundContent(
                            status: status(scenario), model: model, policy: policy,
                            actions: HostBackgroundActions(openOwner: { opened.append($0) }),
                            now: { Self.now })
                    }
                    .environment(\.compactLayout, variant.width < UIScale.pt(720))
                    .environment(\.colorScheme, variant.scheme)
                    .environment(\.automaticViewActionsEnabled, false)
                    .environment(\.windowVisible, true)
                    .background(DashSkin.paper(variant.scheme == .dark))
                    .transaction { $0.animation = nil })
                host.frame = CGRect(x: 0, y: 0, width: variant.width, height: variant.height)
                let window = TestWindowHost.window(contentRect: host.frame)
                window.appearance = NSAppearance(
                    named: variant.scheme == .dark ? .darkAqua : .aqua)
                window.contentView = host
                window.orderBack(nil)
                await settle(window, host: host)
                #expect(abs(host.bounds.width - variant.width) < 1)
                let bitmap = try capture(
                    host, name: "background-\(scenario.rawValue)-\(variant.name)")
                #expect(bitmap.pixelsWide >= Int(variant.width))
                #expect(distinctColors(bitmap) > 4)
                #expect(!TestWindowHost.isExposedOnDesktop(window))
                window.orderOut(nil)
            }
        }
        #expect(opened.isEmpty)
    }

    @Test func quitWaitPanelExplainsWhatEdithIsWaitingFor() async throws {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        let single = HostQuitWaitModel(blockers: ["Screen Recorder"])
        #expect(single.message.hasPrefix("Screen Recorder is still working."))
        #expect(single.status == "Waiting for Screen Recorder")
        let several = HostQuitWaitModel(blockers: [
            "Screen Recorder", "Downloads", "Studio", "Music",
        ])
        #expect(
            several.message.hasPrefix("Screen Recorder, Downloads and 2 more are still working."))
        #expect(several.status == "Waiting for 4 tools")
        #expect(HostQuitWaitModel(blockers: []).message.hasPrefix("Some background work is"))
        for (name, model, zoom, scheme) in [
            ("one-light", single, 1.0, ColorScheme.light),
            ("one-dark", single, 1.0, .dark),
            ("several-light", several, 1.0, .light),
            ("several-zoomed", several, 1.6, .dark),
        ] {
            UIScale.apply(zoom)
            let host = NSHostingView(
                rootView: HostQuitWaitView(model: model)
                    .environment(\.colorScheme, scheme)
                    .transaction { $0.animation = nil })
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            let window = TestWindowHost.window(contentRect: host.frame)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            window.orderBack(nil)
            await settle(window, host: host)
            #expect(abs(host.bounds.width - UIScale.pt(400)) < 1)
            #expect(host.bounds.height > UIScale.pt(150))
            let bitmap = try capture(host, name: "quit-wait-\(name)")
            #expect(distinctColors(bitmap) > 4)
            #expect(!TestWindowHost.isExposedOnDesktop(window))
            window.orderOut(nil)
        }
    }
}
