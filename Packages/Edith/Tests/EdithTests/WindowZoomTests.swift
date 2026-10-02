import AppKit
import Observation
import Testing

@testable import Edith
@testable import EdithKit

@Suite struct WindowZoomTests {
    @Test @MainActor func storeClampsAndInstallsTheDefaultsValue() {
        defer { UIScale.apply(1) }
        UIScale.apply(2)
        #expect(UIScale.current == 1.6)
        #expect(UIScale.pt(10) == 16)
        #expect(UIScale.controlSize == .extraLarge)
        UIScale.apply(0.2)
        #expect(UIScale.current == 0.8)
        #expect(UIScale.controlSize == .regular)
        UIScale.apply(1.2)
        #expect(UIScale.controlSize == .large)
        let defaults = UserDefaults(suiteName: "edith-window-zoom-\(UUID().uuidString)")!
        defaults.set(1.7, forKey: WindowZoom.defaultsKey)
        UIScale.install(from: defaults)
        #expect(UIScale.current == 1.6)
        let empty = UserDefaults(suiteName: "edith-window-zoom-empty-\(UUID().uuidString)")!
        UIScale.install(from: empty)
        #expect(UIScale.current == 1)
    }

    @Test @MainActor func pointReadsAreObserved() {
        defer { UIScale.apply(1) }
        UIScale.apply(1)
        final class Flag: @unchecked Sendable {
            var changed = false
        }
        let flag = Flag()
        withObservationTracking {
            _ = UIScale.pt(10)
        } onChange: {
            flag.changed = true
        }
        UIScale.apply(1.3)
        #expect(flag.changed)
        #expect(UIScale.pt(10) == 13)
    }

    @Test func offMainReadsUseTheCommittedScale() async {
        await MainActor.run { UIScale.apply(1.4) }
        let value = await Task.detached { UIScale.pt(10) }.value
        await MainActor.run { UIScale.apply(1) }
        #expect(value == 14)
    }

    @Test func terminalFocusKeepsItsOwnZoom() {
        #expect(WindowZoomDispatch.consumes(.zoomIn, terminalFocused: false))
        #expect(WindowZoomDispatch.consumes(.zoomOut, terminalFocused: false))
        #expect(WindowZoomDispatch.consumes(.zoomReset, terminalFocused: false))
        #expect(!WindowZoomDispatch.consumes(.zoomIn, terminalFocused: true))
        #expect(!WindowZoomDispatch.consumes(.zoomOut, terminalFocused: true))
        #expect(!WindowZoomDispatch.consumes(.zoomReset, terminalFocused: true))
        #expect(!WindowZoomDispatch.consumes(.select(0), terminalFocused: false))
        #expect(!TerminalZoomFocus.owns(nil))
        #expect(!TerminalZoomFocus.owns(NSView()))
    }

    @Test @MainActor func zoomChangesTheScaleAndLeavesTheFramePolicyAlone() throws {
        defer { UIScale.apply(1) }
        UIScale.apply(1)
        var stored = 1.0
        WindowZoomCommit.perform(1.4) { stored = $0 }
        #expect(stored == 1.4)
        #expect(UIScale.current == 1.4)
        #expect(UIScale.pt(10) == 14)
        let visible = NSRect(x: 0, y: 0, width: 1800, height: 1200)
        #expect(
            MainWindowFramePolicy.minimumSize(visibleFrame: visible)
                == NSSize(width: 960, height: 640))
        #expect(
            MainWindowFramePolicy.defaultSize(visibleFrame: visible)
                == NSSize(width: 1240, height: 820))
        let frame = NSRect(x: 40, y: 80, width: 1000, height: 700)
        #expect(
            MainWindowFramePolicy.normalizedFrame(frame, visibleFrame: visible).size == frame.size)
        #expect(
            MainWindowFramePolicy.fitted(SectionWindow.baseContentSize, visible: visible.size)
                == SectionWindow.baseContentSize)
        #expect(
            MainWindowFramePolicy.fitted(
                SectionWindow.baseMinimumSize, visible: NSSize(width: 400, height: 300))
                == NSSize(width: 400, height: 300))
        let zoomOut = try #require(WindowZoom.adjusted(0.8, for: .zoomOut))
        WindowZoomCommit.perform(zoomOut) { stored = $0 }
        #expect(stored == 0.8)
        #expect(UIScale.current == 0.8)
        #expect(
            MainWindowFramePolicy.minimumSize(visibleFrame: visible)
                == NSSize(width: 960, height: 640))
    }

    @Test func tableMetricsAndPreviewTextFollowTheScale() {
        #expect(DatabaseTableMetrics.points(30, scale: 1.5) == 45)
        #expect(DatabaseTableMetrics.logical(45, scale: 1.5) == 30)
        let source = NSAttributedString(
            string: "row",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)])
        let scaled = PreviewTextScale.attributed(source, scale: 1.6)
        let font = scaled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(abs((font?.pointSize ?? 0) - 18.4) < 0.01)
        #expect(PreviewTextScale.attributed(source, scale: 1) === source)
    }
}
