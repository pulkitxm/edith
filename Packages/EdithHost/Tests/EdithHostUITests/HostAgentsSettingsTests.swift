import AppKit
import EdithExtensionUI
import EdithHostCore
import QuartzCore
import SwiftUI
import Testing

@testable import EdithHost

@MainActor struct HostAgentsFixture {
    static let command = "/Applications/Edith.app/Contents/MacOS/ed"
    static let otherCommand = "/Volumes/Archive/Edith.app/Contents/MacOS/ed"
    let home: URL
    let suite: String
    let defaults: UserDefaults
    var copied: [String] { clipboard.values }
    private let clipboard = Clipboard()

    final class Clipboard {
        var values: [String] = []
    }

    init(tools: HostMCPToolRunner = .none) throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agents-settings-\(UUID().uuidString)")
        suite = "test.edith.agents-settings.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        self.tools = tools
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try Self.write(
            "{\"mcpServers\":{\"edith\":{\"command\":\"\(Self.command)\",\"args\":[\"mcp\"]}}}",
            to: HostMCPClient.cursor.configURL(home: home))
        try Self.write(
            "model = \"synthetic\"\n\n[mcp_servers.edith]\ncommand = \"\(Self.otherCommand)\"\nargs = [\"mcp\"]\n",
            to: HostMCPClient.codex.configURL(home: home))
        try FileManager.default.createDirectory(
            at: HostMCPClient.vscode.configURL(home: home).deletingLastPathComponent(),
            withIntermediateDirectories: true)
    }

    private let tools: HostMCPToolRunner

    var installer: HostMCPInstaller {
        HostMCPInstaller(home: home, command: Self.command, tools: tools)
    }

    func model() -> HostAgentsSettingsModel {
        let clipboard = clipboard
        return HostAgentsSettingsModel(
            installer: installer, defaults: defaults, copy: { clipboard.values.append($0) })
    }

    func clean() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: home)
    }

    static func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
}

@MainActor @Suite(.serialized) struct HostAgentsSettingsTests {
    private struct Variant {
        let name: String
        let width: Double
        let height: Double
        let zoom: Double
        let scheme: ColorScheme

        static let all: [Variant] = [640.0, 1100.0].flatMap { width in
            [1.0, 1.6].flatMap { zoom in
                [ColorScheme.light, .dark].map { scheme in
                    Variant(
                        name:
                            "\(width < 1000 ? "compact" : "regular")-\(zoom == 1 ? "1x" : "zoom")-\(scheme == .dark ? "dark" : "light")",
                        width: width, height: zoom == 1 ? 900 : 1200, zoom: zoom, scheme: scheme)
                }
            }
        }
    }

    @Test func refreshMapsTheFixtureToAllFourStatusesWithoutWriting() async throws {
        let fixture = try HostAgentsFixture()
        defer { fixture.clean() }
        let before = try snapshot(fixture.home)
        let model = fixture.model()
        #expect(model.load.state == .loading)
        await model.refresh()
        #expect(model.load.state == .content)
        #expect(
            model.reports.map(\.connection) == [.manual, .otherEdith, .connected, .notConnected])
        #expect(
            model.reports.map(\.connection.title) == [
                "Needs manual setup", "Points at another Edith", "Connected", "Not connected",
            ])
        #expect(model.pending.map(\.client) == [.claude, .codex, .vscode])
        #expect(model.canConnectAll)
        let manual = try #require(model.manualStep(model.reports[0]))
        #expect(
            manual.snippet
                == "claude mcp add --scope user edith -- \(HostAgentsFixture.command) mcp")
        #expect(model.manualStep(model.reports[2]) == nil)
        #expect(model.guidance(model.reports[2]) == nil)
        #expect(
            model.guidance(model.reports[1])?.message
                == "The edith entry runs \(HostAgentsFixture.otherCommand). Connect replaces it with this Edith."
        )
        #expect(fixture.defaults.bool(forKey: HostSettingsCatalog.getStartedAgentKey))
        #expect(try snapshot(fixture.home) == before)
    }

    @Test func connectAndDisconnectWriteOnlyTheFixtureHome() async throws {
        let fixture = try HostAgentsFixture()
        defer { fixture.clean() }
        let model = fixture.model()
        await model.refresh()
        await model.perform(.connect(.vscode))
        #expect(model.results[.vscode]?.succeeded == true)
        #expect(model.results[.vscode]?.message.contains("Restart the agent to load Edith") == true)
        #expect(model.reports.first { $0.client == .vscode }?.connection == .connected)
        let vscode = try String(
            contentsOf: HostMCPClient.vscode.configURL(home: fixture.home), encoding: .utf8)
        #expect(vscode.contains("\"servers\"") && vscode.contains(HostAgentsFixture.command))

        await model.perform(.connect(.claude))
        let claude = try #require(model.results[.claude])
        #expect(!claude.succeeded)
        #expect(
            claude.snippet
                == "claude mcp add --scope user edith -- \(HostAgentsFixture.command) mcp")
        #expect(
            !FileManager.default.fileExists(
                atPath: HostMCPClient.claude.configURL(home: fixture.home).path))

        await model.perform(.disconnect(.cursor))
        #expect(model.results[.cursor]?.succeeded == true)
        #expect(model.reports.first { $0.client == .cursor }?.connection == .notConnected)
        let backup = HostMCPClient.cursor.configURL(home: fixture.home).path + ".edith-backup"
        #expect(FileManager.default.fileExists(atPath: backup))

        await model.perform(.connectAll)
        #expect(model.results[.codex]?.succeeded == true)
        #expect(model.results[.cursor]?.succeeded == true)
        let codex = try String(
            contentsOf: HostMCPClient.codex.configURL(home: fixture.home), encoding: .utf8)
        #expect(codex.contains("model = \"synthetic\""))
        #expect(
            codex.contains(HostAgentsFixture.command)
                && !codex.contains(HostAgentsFixture.otherCommand))
        #expect(model.reports.map(\.connection) == [.manual, .connected, .connected, .connected])
        #expect(!model.canConnectAll)
        #expect(model.running == nil)

        model.copySnippet("ed mcp install --client all")
        #expect(fixture.copied == ["ed mcp install --client all"])
        #expect(model.copied == "ed mcp install --client all")
    }

    @Test func resultsExplainEveryOutcomeAndCarryTheManualSnippet() {
        func outcome(
            _ client: HostMCPClient, _ action: HostMCPInstaller.Outcome.Action,
            applied: Bool = false,
            run: [String]? = nil, note: String? = nil
        ) -> HostMCPInstaller.Outcome {
            HostMCPInstaller.Outcome(
                client: client, path: "/synthetic/mcp.json", action: action, applied: applied,
                snippet: "{\n  \"servers\": {}\n}\n", run: run, note: note, backup: nil)
        }
        #expect(
            HostAgentResult.connecting(outcome(.cursor, .created, applied: true))?.succeeded == true
        )
        #expect(
            HostAgentResult.connecting(outcome(.cursor, .unchanged))?.message
                == "Already connected.")
        #expect(HostAgentResult.connecting(outcome(.cursor, .notFound)) == nil)
        let skipped = HostAgentResult.connecting(
            outcome(.vscode, .skipped, note: "The existing file is not plain JSON."))
        #expect(skipped?.succeeded == false)
        #expect(skipped?.snippet == "{\n  \"servers\": {}\n}")
        let refused = HostAgentResult.connecting(
            outcome(
                .claude, .skipped, run: ["claude", "mcp", "add"], note: "exited with status 1."))
        #expect(refused?.snippet == "claude mcp add")
        #expect(
            HostAgentResult.disconnecting(outcome(.cursor, .removed, applied: true), path: "~/x")?
                .message == "Disconnected. Restart the agent to unload Edith.")
        let manual = HostAgentResult.disconnecting(
            outcome(.claude, .manual, run: ["claude", "mcp", "remove"], note: "Not found."),
            path: "~/x")
        #expect(manual?.snippet == "claude mcp remove")
        #expect(
            HostAgentResult.disconnecting(outcome(.cursor, .skipped, note: "Bad."), path: "~/x")?
                .message == "Bad. Delete the edith entry from ~/x yourself.")
    }

    @Test func agentMarksUseTheBrandLogosAlreadyShippedForThoseAgents() {
        for client in [HostMCPClient.claude, .codex, .cursor] {
            let name = HostAgentMark.logoName(client)
            #expect(name.flatMap(HostSidebarLogo.image(named:)) != nil, "\(client)")
        }
        #expect(HostAgentMark.logoName(.vscode) == nil)
    }

    @Test func sectionRendersEveryStatusAcrossWidthsZoomAndSchemes() async throws {
        let fixture = try HostAgentsFixture()
        defer { fixture.clean() }
        let loading = fixture.model()
        let statuses = fixture.model()
        await statuses.refresh()
        for variant in Variant.all {
            let skeleton = try await render(variant, name: "agents-loading") {
                settings { HostAgentsSettingsPage(model: loading) }
            }
            #expect(distinctColors(skeleton) > 4)
            let rendered = try await render(variant, name: "agents-status") {
                settings { HostAgentsSettingsPage(model: statuses) }
            }
            #expect(distinctColors(rendered) > 10)
        }
        await statuses.perform(.connect(.vscode))
        await statuses.perform(.connect(.claude))
        for variant in Variant.all {
            let rendered = try await render(variant, name: "agents-results") {
                settings { HostAgentsSettingsPage(model: statuses) }
            }
            #expect(distinctColors(rendered) > 10)
        }
    }

    private func settings<Content: View>(@ViewBuilder content: @escaping () -> Content)
        -> some View
    {
        HostSettingsContainer(category: .constant("mcp"), content: content)
    }

    private func snapshot(_ root: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if let data = try? Data(contentsOf: url) { files[url.path] = data }
        }
        return files
    }

    private func distinctColors(_ bitmap: NSBitmapImageRep) -> Int {
        var colors: Set<UInt32> = []
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 6) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 6) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                colors.insert(
                    UInt32(color.redComponent * 255) << 16 | UInt32(color.greenComponent * 255) << 8
                        | UInt32(color.blueComponent * 255))
            }
        }
        return colors.count
    }

    private func render<Content: View>(
        _ variant: Variant, name: String, @ViewBuilder content: () -> Content
    ) async throws -> NSBitmapImageRep {
        _ = TestWindowHost.application
        let previous = UIScale.current
        UIScale.apply(variant.zoom)
        defer { UIScale.apply(previous) }
        let host = NSHostingView(
            rootView: AnyView(
                content()
                    .frame(width: variant.width, height: variant.height, alignment: .topLeading)
                    .background(DashSkin.paper(variant.scheme == .dark))
                    .environment(\.compactLayout, variant.width < UIScale.pt(720))
                    .environment(\.colorScheme, variant.scheme)
                    .environment(\.automaticViewActionsEnabled, false)
                    .environment(\.loadingAnimationsEnabled, false)
                    .environment(\.windowVisible, false)
                    .environment(\.controlActiveState, .key)
                    .transaction { $0.animation = nil }))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: variant.scheme == .dark ? .darkAqua : .aqua)
        host.frame = CGRect(x: 0, y: 0, width: variant.width, height: variant.height)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.appearance = host.appearance
        window.contentView = host
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        for _ in 0..<8 {
            window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(40))
        }
        CATransaction.flush()
        #expect(!TestWindowHost.isExposedOnDesktop(window))
        #expect(host.bounds.size == CGSize(width: variant.width, height: variant.height))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let capture = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"] {
            let directory = URL(fileURLWithPath: capture, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(
                to: directory.appendingPathComponent("\(name)-\(variant.name).png"),
                options: .atomic)
        }
        return bitmap
    }
}
