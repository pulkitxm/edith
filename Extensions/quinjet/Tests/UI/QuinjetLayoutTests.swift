import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing
@testable import QuinjetUI

@MainActor @Suite(.serialized) struct QuinjetLayoutTests {
    @Test func fullProjectPickerRendersCompactRegularZoomAndBothAppearances() async throws {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        for width in [620.0, 1100.0] {
            for dark in [false, true] {
                for zoom in [1.0, 1.4] {
                    UIScale.apply(zoom)
                    let client = QuinjetClient { _ in
                        try JSONEncoder().encode([
                            QuinjetProject(
                                name: "Synthetic review", commonDir: "/tmp/mock/.git",
                                worktrees: [
                                    QuinjetWorktree(
                                        path: "/tmp/mock", head: "1234567", branch: "main",
                                        current: true, bare: false, detached: false, locked: nil,
                                        prunable: nil)
                                ])
                        ])
                    }
                    let model = QuinjetPageModel(client: client)
                    await model.refreshProjects()
                    let host = NSHostingView(
                        rootView: ExtensionPageHost {
                            QuinjetPage(model: model)
                                .environment(\.compactLayout, width < 720)
                                .environment(\.colorScheme, dark ? .dark : .light)
                                .environment(\.automaticViewActionsEnabled, false)
                                .environment(\.terminalLaunchEnabled, false)
                        })
                    let frame = NSRect(x: 0, y: 0, width: width, height: 760)
                    let window = TestWindowHost.window(contentRect: frame)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    host.frame = frame
                    host.layoutSubtreeIfNeeded()
                    await Task.yield()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
                    #expect(host.fittingSize.width <= width + 1)
                    #expect(!TestWindowHost.isExposedOnDesktop(window))
                    window.close()
                    await model.shutdown()
                }
            }
        }
    }
}
