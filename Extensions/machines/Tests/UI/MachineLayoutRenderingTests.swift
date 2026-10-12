@testable import MachinesExtension
import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing

@Suite @MainActor struct MachineLayoutRenderingTests {
    @Test func fleetRendersAtBothWidthsSchemesAndIncreasedZoom() async throws {
        guard ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil else {
            Issue.record("Layout rendering requires an isolated synthetic fixture."); return
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let directory = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["EDITH_MACHINES_LAYOUT_DIR"]
                ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let priorScale = UIScale.current
        defer { UIScale.apply(priorScale) }
        let model = MachinesModel.shared
        for machine in model.allMachines { model.session(for: machine.id).start() }
        for width in [600.0, 1_180.0] {
            for dark in [false, true] {
                for zoom in [1.0, 1.5] {
                    UIScale.apply(zoom)
                    let view = NSHostingView(
                        rootView:
                            NavigationRouteHost(router: WindowRouter()) {
                                MachinesPage()
                                    .environment(\.compactLayout, width < UIScale.pt(720))
                                    .environment(\.colorScheme, dark ? .dark : .light)
                                    .environment(\.machineConnectionsEnabled, true)
                                    .environment(\.terminalLaunchEnabled, false)
                                    .environment(\.automaticViewActionsEnabled, false)
                                    .environment(\.windowVisible, true)
                            })
                    view.sizingOptions = []
                    let window = NSWindow(
                        contentRect: NSRect(x: -20000, y: -20000, width: width, height: 900),
                        styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = view
                    view.frame = NSRect(x: 0, y: 0, width: width, height: 900)
                    try await Task.sleep(for: .milliseconds(100))
                    view.layoutSubtreeIfNeeded()
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    #expect(bitmap.pixelsWide >= Int(width))
                    #expect(bitmap.pixelsHigh >= 900)
                    #expect(data.count > 10_000)
                    var matchingEdges = 0
                    var sampledEdges = 0
                    for y in stride(
                        from: bitmap.pixelsHigh / 4, to: bitmap.pixelsHigh * 9 / 10, by: 4)
                    {
                        let left = try #require(
                            bitmap.colorAt(x: 3, y: y)?.usingColorSpace(.deviceRGB))
                        let right = try #require(
                            bitmap.colorAt(x: bitmap.pixelsWide - 4, y: y)?.usingColorSpace(
                                .deviceRGB))
                        let difference = max(
                            abs(left.redComponent - right.redComponent),
                            abs(left.greenComponent - right.greenComponent),
                            abs(left.blueComponent - right.blueComponent))
                        if difference < 0.02 { matchingEdges += 1 }
                        sampledEdges += 1
                    }
                    #expect(Double(matchingEdges) / Double(sampledEdges) > 0.95)
                    let name = "fleet-\(Int(width))-\(dark ? "dark" : "light")-\(zoom).png"
                    try data.write(to: directory.appendingPathComponent(name))
                    window.close()
                }
            }
        }
    }
}
