import AppKit
import EdithHostCore
import SwiftUI
import Testing

@testable import EdithHost

@MainActor
@Suite(.serialized)
struct HostNotchInteractionTests {
    private func chromeRequest() -> HostExtensionContentRequest {
        HostExtensionContentRequest(
            extensionID: "notchShelf", location: "notch", section: "panel.1",
            presentationID: UUID())
    }

    private func mounted(
        _ request: HostExtensionContentRequest, size: CGSize,
        root: some View
    ) async throws -> HostRemoteViewController {
        _ = TestWindowHost.application
        let container = HostNotchContainerController()
        container.loadViewIfNeeded()
        let window = TestWindowHost.window(contentRect: CGRect(origin: .zero, size: size))
        window.contentView = container.view
        container.view.frame = CGRect(origin: .zero, size: size)
        let remote = HostRemoteViewController(
            request: request,
            present: { _ in NSHostingController(rootView: root) },
            update: { _ in })
        container.attach(remote, rectangle: nil, native: false)
        for _ in 0..<20 where !remote.connected {
            try await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<6 {
            container.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        return remote
    }

    @Test func notchChromeFillsThePanelSoItsLowerControlsReceiveEvents() async throws {
        let size = CGSize(width: 640, height: 320)
        let remote = try await mounted(
            chromeRequest(), size: size, root: GeometryReader { _ in Color.clear })
        #expect(remote.connected)
        let content = try #require(remote.view.subviews.first)
        #expect(content.frame == CGRect(origin: .zero, size: size))
    }

    @Test func nativeCardFillsItsSlotAndStillReportsItsNaturalHeight() async throws {
        _ = TestWindowHost.application
        let container = HostNotchContainerController()
        container.loadViewIfNeeded()
        let window = TestWindowHost.window(contentRect: CGRect(x: 0, y: 0, width: 640, height: 320))
        window.contentView = container.view
        container.view.frame = CGRect(x: 0, y: 0, width: 640, height: 320)
        let request = HostExtensionContentRequest(
            extensionID: "herdr", location: "notch", section: "agents", presentationID: UUID())
        let remote = HostRemoteViewController(
            request: request,
            present: { _ in
                NSHostingController(
                    rootView: ScrollView {
                        VStack(spacing: 0) {
                            Color.clear.frame(height: 90)
                        }
                    }
                    .background(Color.blue.onTapGesture {}))
            },
            update: { _ in })
        var reported: [Double] = []
        remote.changed = { if let height = remote.contentHeight { reported.append(height) } }
        let slot = CGRect(x: 20, y: 60, width: 300, height: 200)
        container.attach(remote, rectangle: slot, native: true)
        for _ in 0..<20 where !remote.connected {
            try await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<6 {
            container.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let content = try #require(remote.view.subviews.first)
        #expect(content.frame.height >= slot.height)
        let hit = remote.view.hitTest(CGPoint(x: slot.midX, y: slot.maxY - 10))
        #expect(hit?.isDescendant(of: content) == true)
        #expect(reported.allSatisfy { $0 < slot.height })
    }

    @Test func measuredCardStillReportsGrowth() async throws {
        _ = TestWindowHost.application
        let container = HostNotchContainerController()
        container.loadViewIfNeeded()
        container.view.frame = CGRect(x: 0, y: 0, width: 640, height: 320)
        let request = HostExtensionContentRequest(
            extensionID: "music", location: "notch", section: "music", presentationID: UUID())
        let remote = HostRemoteViewController(
            request: request,
            present: { _ in
                NSHostingController(rootView: Color.clear.frame(width: 200, height: 92))
            },
            update: { _ in })
        container.attach(
            remote, rectangle: CGRect(x: 0, y: 40, width: 200, height: 160), native: true)
        for _ in 0..<20 where !remote.connected {
            try await Task.sleep(for: .milliseconds(10))
        }
        container.view.layoutSubtreeIfNeeded()
        #expect(remote.contentHeight == 92)
    }

    @Test func horizontalScrollOverANativeCardReachesTheChromeBeneathIt() {
        _ = TestWindowHost.application
        let container = HostNotchContainerController()
        container.loadViewIfNeeded()
        let window = TestWindowHost.window(contentRect: CGRect(x: 0, y: 0, width: 640, height: 320))
        window.contentView = container.view
        let chrome = NSViewController()
        let shelf = NSScrollView()
        shelf.hasHorizontalScroller = true
        shelf.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 2000, height: 300))
        chrome.view = shelf
        container.attach(chrome, rectangle: nil, native: false)
        let card = NSViewController()
        card.view = NSView()
        let slot = CGRect(x: 20, y: 60, width: 200, height: 160)
        container.attach(card, rectangle: slot, native: true)
        let onCard = container.view.convert(CGPoint(x: slot.midX, y: slot.midY), to: nil)
        let offCard = container.view.convert(CGPoint(x: 500, y: slot.midY), to: nil)

        let target = container.chromeScrollTarget(at: onCard, deltaX: -24, deltaY: 2)
        #expect(target?.isDescendant(of: shelf) == true)
        #expect(container.chromeScrollTarget(at: onCard, deltaX: 1, deltaY: -18) == nil)
        #expect(container.chromeScrollTarget(at: offCard, deltaX: -24, deltaY: 0) == nil)
    }
}
