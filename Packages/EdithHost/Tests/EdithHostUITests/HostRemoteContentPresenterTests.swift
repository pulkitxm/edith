import AppKit
import EdithHostCore
@preconcurrency import ExtensionKit
import Testing

@testable import EdithHost

@MainActor
@Suite(.serialized)
struct HostRemoteContentPresenterTests {
    @Test func activationReceivesCurrentGeometryAndCoalescesOwnedUpdates() async throws {
        var connections = 0
        var states: [HostRemoteViewState] = []
        let activation = RemoteTestGate()
        let update = RemoteTestGate()
        let request = HostExtensionContentRequest(
            extensionID: "music", location: "music.footer", section: "music", presentationID: UUID()
        )
        let controller = HostRemoteViewController(
            request: request, remote: EXHostViewController(),
            connect: { _, state, _ in
                connections += 1
                states.append(state)
                await activation.wait()
            },
            update: { state in
                states.append(state)
                await update.wait()
            })
        defer { activation.release(); update.release(); controller.detach() }
        controller.apply(compact: true, visible: true, width: 380)
        try controller.activate(
            through: NSXPCConnection(serviceName: "com.pulkit.edith.tests.remote"))
        await settle { activation.waiting }
        #expect(connections == 1)
        #expect(states == [HostRemoteViewState(compact: true, visible: true, width: 380)])
        #expect(throws: (any Error).self) {
            try controller.activate(
                through: NSXPCConnection(serviceName: "com.pulkit.edith.tests.remote"))
        }
        controller.apply(compact: false, visible: true, width: 880)
        activation.release()
        await settle { update.waiting }
        #expect(controller.connected)
        #expect(states.last == HostRemoteViewState(compact: false, visible: true, width: 880))
        controller.apply(compact: false, visible: false, width: 880)
        controller.apply(compact: true, visible: false, width: 500)
        controller.apply(compact: true, visible: true, width: 520)
        update.release()
        await settle { states.count == 3 }
        #expect(states.last == HostRemoteViewState(compact: true, visible: true, width: 520))
        update.release()
        await Task.yield()
        controller.apply(compact: true, visible: false, width: 520)
        await settle { states.count == 4 }
        #expect(states.last?.visible == false)
        update.release()
        controller.detach()
        controller.apply(compact: false, visible: true, width: 1000)
        await Task.yield()
        #expect(states.count == 4)
        #expect(!controller.connected)
        #expect(controller.detached)
    }

    @Test func cancelledActivationCannotReviveDetachedScene() async throws {
        let gate = RemoteTestGate()
        var updates = 0
        let controller = HostRemoteViewController(
            request: HostExtensionContentRequest(
                extensionID: "calendar", location: "main", section: "calendar",
                presentationID: UUID()), remote: EXHostViewController(),
            connect: { _, _, receive in
                await gate.wait()
                receive(HostRemoteEvent(kind: "height", presentationID: UUID(), height: 200))
            }, update: { _ in updates += 1 })
        try controller.activate(
            through: NSXPCConnection(serviceName: "com.pulkit.edith.tests.remote"))
        await settle { gate.waiting }
        controller.detach()
        gate.release()
        await Task.yield()
        await Task.yield()
        #expect(controller.detached)
        #expect(!controller.connected)
        #expect(updates == 0)
        #expect(controller.failure == nil)
        #expect(controller.contentHeight == nil)
    }

    @Test func heightEventsOnlyResizeCurrentIntrinsicScene() {
        let presentation = UUID()
        for location in [
            "main", "settings", "music.detail", "home", "music.footer", "sidebar.utility",
        ] {
            let controller = HostRemoteViewController(
                request: HostExtensionContentRequest(
                    extensionID: "music", location: location, section: "music",
                    presentationID: presentation), remote: EXHostViewController(),
                connect: { _, _, _ in }, update: { _ in })
            let window = TestWindowHost.window(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 400))
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            defer { controller.detach(); window.close() }
            for height in [-1.0, Double.infinity, Double.nan, 16_385] {
                controller.receive(
                    HostRemoteEvent(kind: "height", presentationID: presentation, height: height))
                #expect(controller.contentHeight == nil)
            }
            controller.receive(HostRemoteEvent(kind: "height", presentationID: UUID(), height: 100))
            controller.receive(
                HostRemoteEvent(kind: "unknown", presentationID: presentation, height: 100))
            #expect(controller.contentHeight == nil)
            controller.receive(
                HostRemoteEvent(kind: "height", presentationID: presentation, height: 120))
            let intrinsic = !["main", "settings", "music.detail"].contains(location)
            #expect(controller.contentHeight == (intrinsic ? 120 : nil))
            #expect(
                controller.view.intrinsicContentSize.height
                    == (intrinsic ? 120 : NSView.noIntrinsicMetric))
            controller.receive(
                HostRemoteEvent(kind: "height", presentationID: presentation, height: 0))
            #expect(controller.contentHeight == (intrinsic ? 0 : nil))
            #expect(!TestWindowHost.isExposedOnDesktop(window))
            controller.detach()
            controller.receive(
                HostRemoteEvent(kind: "height", presentationID: presentation, height: 140))
            #expect(controller.contentHeight == (intrinsic ? 0 : nil))
            #expect(controller.children.isEmpty)
        }
    }

    @Test func geometryRejectsNonfiniteAndOutOfBoundsWidths() {
        for width in [Double.nan, .infinity, -.infinity, -1] {
            #expect(HostRemoteViewState(compact: true, visible: false, width: width).width == 0)
        }
        #expect(HostRemoteViewState(compact: false, visible: true, width: 20_000).width == 16_384)
        #expect(HostRemoteViewState(compact: false, visible: true, width: 520).width == 520)
    }

    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(condition())
    }
}

@MainActor
private final class RemoteTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}
