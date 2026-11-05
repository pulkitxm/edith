import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import QuinjetUI

@MainActor @Suite("QuinjetCaptureTests", .serialized)
struct QuinjetCaptureTests {
    enum Fixture: String, CaseIterable {
        case firstRun = "first-run"
        case missingTool = "missing-tool"
        case failed
        case populated
    }

    struct Variant {
        let name: String
        let size: CGSize
        let dark: Bool
        var zoom = 1.0
    }

    static let variants = [
        Variant(name: "regular-light", size: CGSize(width: 1100, height: 760), dark: false),
        Variant(name: "regular-dark", size: CGSize(width: 1100, height: 760), dark: true),
        Variant(name: "wide-light", size: CGSize(width: 1600, height: 900), dark: false),
        Variant(name: "compact-light", size: CGSize(width: 640, height: 700), dark: false),
        Variant(name: "compact-dark", size: CGSize(width: 640, height: 700), dark: true),
        Variant(name: "zoom-1.6", size: CGSize(width: 1100, height: 760), dark: false, zoom: 1.6),
    ]

    static func client(_ fixture: Fixture) -> QuinjetClient {
        QuinjetClient { _ in
            switch fixture {
            case .firstRun:
                return try JSONEncoder().encode([QuinjetProject]())
            case .missingTool:
                throw QuinjetClientError.notInstalled
            case .failed:
                throw CocoaError(.fileReadCorruptFile)
            case .populated:
                return try JSONEncoder().encode(
                    ["sample-api", "sample-web", "sample-cli", "sample-docs"].map { name in
                        QuinjetProject(
                            name: name, commonDir: "/tmp/mock/\(name)/.git",
                            worktrees: [
                                QuinjetWorktree(
                                    path: "/tmp/mock/\(name)", head: "1234567", branch: "main",
                                    current: true, bare: false, detached: false, locked: nil,
                                    prunable: nil),
                                QuinjetWorktree(
                                    path: "/tmp/mock/\(name)-review", head: "7654321",
                                    branch: "review", current: false, bare: false, detached: false,
                                    locked: nil, prunable: nil),
                            ])
                    })
            }
        }
    }

    @Test(arguments: Fixture.allCases)
    func pickerStatesFitAtEverySize(_ fixture: Fixture) async throws {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        for variant in Self.variants {
            UIScale.apply(variant.zoom)
            let model = QuinjetPageModel(client: Self.client(fixture))
            await model.refreshProjects()
            let compact = variant.size.width < UIScale.pt(720)
            let host = NSHostingView(
                rootView: QuinjetPage(model: model)
                    .environment(\.compactLayout, compact)
                    .environment(\.colorScheme, variant.dark ? .dark : .light)
                    .environment(\.controlActiveState, .key)
                    .environment(\.automaticViewActionsEnabled, false)
                    .environment(\.terminalLaunchEnabled, false))
            host.appearance = NSAppearance(named: variant.dark ? .darkAqua : .aqua)
            host.sizingOptions = []
            let frame = NSRect(origin: .zero, size: variant.size)
            let window = TestWindowHost.window(contentRect: frame)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.frame = frame
            for _ in 0..<8 {
                window.layoutIfNeeded()
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(40))
            }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
            #expect(host.fittingSize.width <= variant.size.width + 1)
            #expect(!TestWindowHost.isExposedOnDesktop(window))
            if let path = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(
                    to: directory.appendingPathComponent(
                        "quinjet-\(fixture.rawValue)-\(variant.name).png"))
            }
            window.close()
            await model.shutdown()
        }
    }

    private func capture<V: View>(
        _ name: String, variant: Variant, content: () -> V
    ) async throws {
        let compact = variant.size.width < UIScale.pt(720)
        let host = NSHostingView(
            rootView: content()
                .environment(\.compactLayout, compact)
                .environment(\.colorScheme, variant.dark ? .dark : .light)
                .environment(\.controlActiveState, .key)
                .environment(\.automaticViewActionsEnabled, false)
                .environment(\.terminalLaunchEnabled, false))
        host.appearance = NSAppearance(named: variant.dark ? .darkAqua : .aqua)
        host.sizingOptions = []
        let frame = NSRect(origin: .zero, size: variant.size)
        let window = TestWindowHost.window(contentRect: frame)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = frame
        for _ in 0..<8 {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
        #expect(!TestWindowHost.isExposedOnDesktop(window))
        if let path = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(
                to: directory.appendingPathComponent("quinjet-\(name)-\(variant.name).png"))
        }
        window.close()
    }

    @Test func projectListSkeletonKeepsThePageEdges() async throws {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        for variant in Self.variants {
            UIScale.apply(variant.zoom)
            try await capture("project-list-loading", variant: variant) {
                QuinjetProjectListSkeleton(dark: variant.dark)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(DashSkin.paper(variant.dark))
            }
        }
    }

    @Test func machineStripShowsEveryConnectionState() async throws {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        let machines = QuinjetMachines(renderingOnly: true)
        machines.adopt(
            [
                Machine(name: "build-server", host: "build.example.invalid", username: "deploy"),
                Machine(name: "garage-pi", host: "10.0.0.42", username: "pi"),
            ], states: [])
        #expect(machines.allMachines.count == 3)
        for variant in Self.variants {
            UIScale.apply(variant.zoom)
            try await capture("machine-strip", variant: variant) {
                VStack(alignment: .leading) {
                    QuinjetMachineStrip(
                        machines: machines, selection: QuinjetMachines.localMachineID,
                        select: { _ in })
                    Spacer()
                }
                .padding(UIScale.pt(16))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(DashSkin.paper(variant.dark))
            }
        }
    }

    @Test func openWorkspaceShowsTheReviewToolbar() async throws {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        for variant in Self.variants {
            UIScale.apply(variant.zoom)
            let model = QuinjetPageModel(client: Self.client(.populated))
            await model.refreshProjects()
            let project = try #require(model.projects.first)
            let worktree = try #require(project.worktrees.first)
            let tab = try #require(model.selectedTab)
            model.open(
                worktree, projectName: project.name, available: project.worktrees, in: tab,
                launchEnabled: false)
            try await capture("workspace", variant: variant) { QuinjetPage(model: model) }
            await model.shutdown()
        }
    }
}
