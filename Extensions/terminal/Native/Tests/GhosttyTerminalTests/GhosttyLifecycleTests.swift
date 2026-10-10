import AppKit
import GhosttyKit
@testable import GhosttyTerminal
import Testing

@Suite(.serialized) struct GhosttyLifecycleTests {
    @Test @MainActor func closingWithALiveProcessDoesNotRequireConfirmation() async {
        let view = GhosttyTerminalView(
            externalIO: TestWindowHost.inertIO())
        var exitCodes: [Int32?] = []
        view.onClose = { exitCodes.append($0) }

        view.reportClosed(processAlive: true)
        await Task.yield()

        #expect(exitCodes.count == 1)
        #expect(exitCodes[0] == nil)
    }

    @Test @MainActor func anEmptyFrameDuringRehostingKeepsTheTerminalGrid() throws {
        let window = TestWindowHost.window(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600))
        let view = GhosttyTerminalView(
            externalIO: TestWindowHost.inertIO())
        defer {
            view.removeFromSuperview()
            window.contentView = nil
            view.shutdown()
        }
        let pane = NSSize(width: 446, height: 303)
        window.contentView = NSView(frame: window.contentLayoutRect)
        view.frame = NSRect(origin: .zero, size: pane)
        window.contentView?.addSubview(view)
        let surface = try #require(view.surface)
        let laidOut = ghostty_surface_size(surface)

        view.setFrameSize(.zero)
        let collapsed = ghostty_surface_size(surface)
        view.setFrameSize(pane)
        let restored = ghostty_surface_size(surface)

        #expect(laidOut.columns > 10)
        #expect(collapsed.columns == laidOut.columns)
        #expect(collapsed.rows == laidOut.rows)
        #expect(restored.columns == laidOut.columns)
        #expect(restored.rows == laidOut.rows)
    }

    @Test @MainActor func anInitiallyEmptyViewStartsAfterReceivingItsLayoutSize() throws {
        let window = TestWindowHost.window(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600))
        let view = GhosttyTerminalView(
            externalIO: TestWindowHost.inertIO())
        var readySizes: [NSSize] = []
        view.onReady = { readySizes.append(view.bounds.size) }
        defer {
            view.removeFromSuperview()
            window.contentView = nil
            view.shutdown()
        }
        window.contentView = NSView(frame: window.contentLayoutRect)
        window.contentView?.addSubview(view)

        #expect(view.surface == nil)
        #expect(readySizes.isEmpty)

        let pane = NSSize(width: 446, height: 303)
        view.setFrameSize(pane)
        view.layoutSubtreeIfNeeded()
        let surface = try #require(view.surface)
        let size = ghostty_surface_size(surface)
        let backingSize = view.convertToBacking(view.bounds.size)

        #expect(size.width_px == UInt32(backingSize.width))
        #expect(size.height_px == UInt32(backingSize.height))
        #expect(view.layer?.bounds.size == view.bounds.size)
        #expect(readySizes == [pane])
    }

    @Test @MainActor func exitedRendererRetainsScreenAndRejectsLateOutput() async throws {
        let window = TestWindowHost.window(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400))
        for _ in 0..<8 {
            let exiting = GhosttyTerminalView(externalIO: TestWindowHost.inertIO())
            exiting.frame = window.contentLayoutRect
            window.contentView = exiting
            _ = try #require(exiting.surface)
            #expect(exiting.receiveOutput(Data("retained-screen".utf8)))
            #expect(exiting.processExited(7))
            #expect(!exiting.receiveOutput(Data("late-output".utf8)))
            #expect(!exiting.setTermios(canonical: true, echo: false))
            #expect(exiting.performBindingAction("select_all"))
            #expect(exiting.selectedText()?.contains("retained-screen") == true)
            window.contentView = nil
            exiting.shutdown()
            let replacement = GhosttyTerminalView(externalIO: TestWindowHost.inertIO())
            replacement.frame = window.contentLayoutRect
            window.contentView = replacement
            _ = try #require(replacement.surface)
            for _ in 0..<20 { try await Task.sleep(for: .milliseconds(10)) }
            #expect(replacement.surface != nil)
            #expect(replacement.receiveOutput(Data("replacement".utf8)))
            window.contentView = nil
            replacement.shutdown()
        }
        #expect(TestWindowHost.exposedWindows.isEmpty)
    }
}
