import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing
@testable import HerdrUI

@Suite(.serialized) @MainActor struct AgentConnectionsRenderingTests {
    @Test func settingsAndExactApprovalInputsRenderAtCompactRegularAndZoomedWidths() async throws {
        _ = TestWindowHost.application
        let scale = UIScale.current
        defer { UIScale.apply(scale) }
        let suite = "activity-render-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = AgentActivityMonitor(defaults: defaults)
        await monitor.save(.init(providers: ["claude": .init(observing: true, approvals: true)]))
        _ = await monitor.surfaceSnapshot()
        var event = AgentActivityEvent(
            provider: .claude, sessionID: "synthetic-session", eventName: "PermissionRequest",
            phase: .permission, project: "/tmp/synthetic-project")
        event.permissionRequest = true
        event.tool = "Read"
        event.permissionInput = #"{"file_path":"/tmp/synthetic.txt","limit":100}"#
        _ = await monitor.service.ingest(event)
        await monitor.refresh()
        let request = try #require(monitor.activity.approvals.first)
        let attributes = ["AXManualAccessibility", "AXEnhancedUserInterface"].map {
            NSAccessibility.Attribute(rawValue: $0)
        }
        let previous = attributes.map { NSApp.accessibilityAttributeValue($0) }
        for key in attributes { NSApp.accessibilitySetValue(true, forAttribute: key) }
        defer {
            for (key, value) in zip(attributes, previous) {
                NSApp.accessibilitySetValue(value ?? false, forAttribute: key)
            }
        }
        for width in [340.0, 780.0] {
            for zoom in [1.0, 1.5] {
                UIScale.apply(zoom)
                for scheme in [ColorScheme.light, .dark] {
                    let host = NSHostingView(
                        rootView:
                            ScrollView {
                                AgentApprovalCard(
                                    request: request, monitor: monitor, dense: width < 400,
                                    showsActions: true
                                ).padding(16)
                            }
                            .environment(\.colorScheme, scheme))
                    host.frame = CGRect(x: 0, y: 0, width: width, height: 360)
                    let window = TestWindowHost.window(contentRect: host.frame)
                    window.contentView = host

                    for _ in 0..<4 {
                        window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    let allow = try #require(find(host, label: "Allow once"))
                    let deny = try #require(find(host, label: "Deny"))
                    for button in [allow, deny] {
                        let frame = (button as AnyObject).accessibilityFrame?() ?? .zero
                        #expect(frame.width > 0 && frame.maxX <= window.frame.maxX)
                        #expect(frame.minX >= window.frame.minX)
                    }

                }
            }
        }
        UIScale.apply(1)
        let settings = NSHostingView(
            rootView: AgentConnectionsPane(monitor: monitor)
                .environment(\.automaticViewActionsEnabled, false))
        settings.frame = CGRect(x: 0, y: 0, width: 780, height: 680)
        let window = TestWindowHost.window(contentRect: settings.frame)
        window.contentView = settings;
        for _ in 0..<4 {
            window.layoutIfNeeded(); settings.layoutSubtreeIfNeeded();
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(find(settings, label: "Review hook setup") != nil)
        #expect(find(settings, label: "Remove hooks") != nil)

        #expect(monitor.activity.approvals.count == 1)
        await monitor.shutdown()
    }

    private func find(_ node: NSObject, label: String, depth: Int = 0) -> NSObject? {
        guard depth < 64 else { return nil }
        if (node as AnyObject).accessibilityLabel?() == label,
            (node as AnyObject).accessibilityRole?() == NSAccessibility.Role.button
        {
            return node
        }
        for child in (node as AnyObject).accessibilityChildren?() as? [NSObject] ?? [] {
            if let result = find(child, label: label, depth: depth + 1) { return result }
        }
        return nil
    }
}
