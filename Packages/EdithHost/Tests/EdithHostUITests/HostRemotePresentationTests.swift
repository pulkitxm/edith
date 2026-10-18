import AppKit
import EdithExtensionUI
import SwiftUI
import Testing

@MainActor struct HostRemotePresentationTests {
    @Test func originalPageHostUsesEachRemoteSceneVisibilityAndCompactState() async throws {
        let first = ExtensionPresentationState(
            compact: true, visible: false, availableWidth: 540, intrinsic: false)
        let second = ExtensionPresentationState(
            compact: false, visible: true, availableWidth: 900, intrinsic: false)
        var observations: [[Bool]?] = [nil, nil]
        let firstView = first.withContext {
            ExtensionPageHost { SceneEnvironmentProbe { observations[0] = $0 } }
        }
        let secondView = second.withContext {
            ExtensionPageHost { SceneEnvironmentProbe { observations[1] = $0 } }
        }
        #expect(ExtensionPresentationState.current == nil)
        let hosts = [NSHostingView(rootView: firstView), NSHostingView(rootView: secondView)]
        let windows = hosts.map { host in
            host.frame = NSRect(x: 0, y: 0, width: 900, height: 650)
            let window = TestWindowHost.window(contentRect: host.frame)
            window.contentView = host
            window.orderBack(nil)
            return window
        }
        defer { windows.forEach { $0.orderOut(nil) } }
        try await settle(hosts) { observations == [[true, false], [false, true]] }
        first.visible = true
        second.compact = true
        try await settle(hosts) { observations == [[true, true], [true, true]] }
        first.visible = false
        try await settle(hosts) { observations == [[true, false], [true, true]] }
    }

    private func settle<V: View>(_ hosts: [NSHostingView<V>], until condition: () -> Bool)
        async throws
    {
        for _ in 0..<50 {
            hosts.forEach {
                $0.layoutSubtreeIfNeeded(); $0.displayIfNeeded()
            }
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }
}

private struct SceneEnvironmentProbe: View {
    @Environment(\.compactLayout) private var compact
    @Environment(\.windowVisible) private var visible
    let changed: ([Bool]) -> Void

    var body: some View {
        Text("Synthetic scene")
            .onChange(of: [compact, visible], initial: true) { changed([compact, visible]) }
    }
}
