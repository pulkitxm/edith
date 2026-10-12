import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import SwiftUI
import Testing

@testable import EdithHost

@MainActor @Suite(.serialized) struct HostToolingSettingsRenderingTests {
    @Test func coreTerminalCategoryDoesNotRequireDownloadedOrActiveExtensions() throws {
        let empty = HostNavigationCatalog.settingsSections(installed: [], pending: [])
        let terminal = try #require(empty.first { $0.id == "terminal" })
        #expect(terminal.extensionID == nil)
        let pending = HostNavigationCatalog.settingsSections(
            installed: ["terminal"], pending: ["terminal"])
        #expect(pending.contains(terminal))
        #expect(!empty.contains { $0.extensionID == "jev" })
    }

    @Test func originalToolingSectionsRenderNeverVisibleAcrossLayoutsWithoutImplicitActions()
        async throws
    {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tooling-render-\(UUID().uuidString)")
        let bin = home.appendingPathComponent("bin")
        let executable = home.appendingPathComponent("Fixture.app/Contents/Resources/ed-launcher")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let suite = "test.edith.tooling-render.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let tooling = HostToolingCLI(home: home, executable: executable, directory: bin, path: [])
        let counter = ToolingRenderCounter()
        var copied: [String] = []
        let model = HostToolingSettingsModel(
            defaults: defaults,
            execute: { arguments in
                await counter.record(arguments)
                return try tooling.execute(arguments)
            }, copy: { copied.append($0) })
        let previousScale = UIScale.current
        defer {
            model.cancel()
            UIScale.apply(previousScale)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: home)
        }
        await model.refresh()
        #expect(model.status?.tools.bundled == true)
        #expect(model.toolsHelp.contains("not on your PATH"))
        for width in [420.0, 1000.0] {
            for zoom in [1.0, 1.5] {
                UIScale.apply(zoom)
                for scheme in [ColorScheme.light, .dark] {
                    let view = HostToolingSettingsPage(model: model)
                        .environment(\.automaticViewActionsEnabled, false)
                        .environment(\.compactLayout, width == 420)
                        .environment(\.windowVisible, false)
                        .environment(\.colorScheme, scheme)
                    let host = NSHostingView(rootView: view)
                    host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 1300)
                    let window = TestWindowHost.window(contentRect: host.frame)
                    window.contentView = host
                    defer { window.close() }
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    #expect(bitmap.pixelsWide >= Int(width) && bitmap.pixelsHigh >= 1300)
                    #expect(host.fittingSize.width.isFinite && host.fittingSize.height.isFinite)
                    #expect(
                        !window.isVisible && !window.isKeyWindow
                            && !TestWindowHost.isExposedOnDesktop(window))
                    var colors: Set<UInt32> = []
                    for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
                            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                                colors.insert(
                                    UInt32(color.redComponent * 255) << 16 | UInt32(
                                        color.greenComponent * 255) << 8
                                        | UInt32(color.blueComponent * 255))
                            }
                        }
                    }
                    #expect(colors.count > 10)
                }
            }
        }
        #expect(await counter.arguments == [["status", "--json"]])
        #expect(copied.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: bin.appendingPathComponent("ed").path))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".zshrc").path))
        #expect(!FileManager.default.fileExists(atPath: tooling.completionFile(.zsh).path))
    }
}

private actor ToolingRenderCounter {
    var arguments: [[String]] = []
    func record(_ value: [String]) { arguments.append(value) }
}
