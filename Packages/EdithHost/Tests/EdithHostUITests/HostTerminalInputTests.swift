import AppKit
import EdithExtensionUI
import EdithHostCore
import Testing

@testable import EdithHost

@MainActor
@Suite(.serialized)
struct HostTerminalInputTests {
    @Test func onlyOriginalFontCommandsAreForwarded() {
        #expect(HostTerminalInput.fontZoom(.zoomIn) == .fontZoomIn)
        #expect(HostTerminalInput.fontZoom(.zoomOut) == .fontZoomOut)
        #expect(HostTerminalInput.fontZoom(.zoomReset) == .fontZoomReset)
        #expect(HostTerminalInput.fontZoom(.select(1)) == nil)
    }

    @Test func neverVisibleWindowStateAndNativeCloseArePinnedToExactPresentation() async throws {
        let fixture = TerminalInputFixture()
        let input = fixture.input()
        let foreign = TestWindowHost.window(contentRect: .zero)
        defer { input.stop(); fixture.window.close(); foreign.close() }
        input.stateChanged()
        await settle { fixture.events.count == 1 }
        let initial = try #require(fixture.events.first)
        #expect(initial.presentationID == fixture.id)
        #expect(initial.sequence == 1)
        #expect(!initial.key && !initial.visible && initial.action == nil)
        #expect(initial.active == NSApp.isActive)
        foreign.close()
        await Task.yield()
        #expect(fixture.events.count == 1)
        fixture.window.close()
        await settle { fixture.events.count == 2 }
        let closed = try #require(fixture.events.last)
        #expect(closed.presentationID == fixture.id)
        #expect(closed.sequence == 2 && closed.action == .windowClosed)
        #expect(!closed.active && !closed.key && !closed.visible)
        input.stateChanged()
        await Task.yield()
        #expect(fixture.events.count == 2)
        #expect(!fixture.window.isVisible && !foreign.isVisible)
    }

    @Test func unavailableOrHiddenInputDoesNotQueryFocusOrConsumeGlobalCommands() async {
        let fixture = TerminalInputFixture()
        fixture.available = false
        let input = fixture.input()
        defer { input.stop(); fixture.window.close() }
        var fallback = 0
        input.stateChanged()
        #expect(!input.consumeZoom(.zoomIn) { fallback += 1 })
        await Task.yield()
        #expect(fixture.events.isEmpty && fixture.focusQueries == 0)
        fixture.available = true
        input.stateChanged()
        await settle { fixture.events.count == 1 }
        #expect(!input.consumeZoom(.zoomIn) { fallback += 1 })
        #expect(fallback == 0 && fixture.focusQueries == 0)
        #expect(!fixture.window.isVisible)
    }

    @Test func stopCancelsAndWaitsForOwnedInFlightUpdateWithoutLateWork() async {
        let fixture = TerminalInputFixture()
        let gate = TerminalInputGate()
        fixture.gate = gate
        let input = fixture.input()
        defer { input.stop(); fixture.window.close() }
        input.stateChanged()
        await settle { gate.waiting }
        input.stateChanged()
        var finished = false
        let stop = Task {
            await input.stopAndWait(); finished = true
        }
        await Task.yield()
        #expect(!finished)
        gate.release()
        await stop.value
        #expect(finished && fixture.cancelled)
        #expect(fixture.events.count == 1)
        input.stateChanged()
        fixture.window.close()
        await Task.yield()
        #expect(fixture.events.count == 1 && input.failure == nil)
    }

    @Test func rejectedStateAcknowledgementRetainsFailureAndDoesNotInventFocus() async {
        let fixture = TerminalInputFixture()
        fixture.accept = false
        let input = fixture.input()
        defer { input.stop(); fixture.window.close() }
        input.stateChanged()
        await settle { input.failure != nil }
        #expect(fixture.events.count == 1 && fixture.focusQueries == 0)
        fixture.accept = true
        input.stateChanged()
        await settle { fixture.events.count == 2 && input.failure == nil }
        #expect(fixture.events.last?.sequence == 2)
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }
}

@MainActor
private final class TerminalInputFixture {
    let id = UUID()
    let window = TestWindowHost.window(contentRect: .zero, styleMask: [.titled, .closable])
    var available = true
    var accept = true
    var events: [HostTerminalUIEvent] = []
    var focusQueries = 0
    var gate: TerminalInputGate?
    var cancelled = false

    func input() -> HostTerminalInput {
        HostTerminalInput(
            presentationID: id,
            client: HostTerminalInputClient(
                update: { [self] event in
                    events.append(event)
                    if let gate { await gate.wait() }
                    cancelled = Task.isCancelled
                    return accept
                },
                status: { [self] in
                    focusQueries += 1
                    return HostTerminalUIStatus(presentationID: id, focused: false)
                }),
            window: { [self] in window }, visible: { true },
            available: { [self] in available }, ownsResponder: { _ in true })
    }
}

@MainActor
private final class TerminalInputGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
