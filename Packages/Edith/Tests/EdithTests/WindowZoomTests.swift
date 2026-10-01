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

    @Test func zoomGrowsContentAndStopsAtTheScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1800, height: 1200)
        let minimum = MainWindowFramePolicy.minimumSize(visibleFrame: visible, scale: 1.5)
        #expect(minimum == NSSize(width: 1440, height: 960))
        let grown = MainWindowFramePolicy.zoomedContentSize(
            current: NSSize(width: 1000, height: 700), minimum: minimum, visible: visible.size,
            from: 1, to: 1.5)
        #expect(grown == NSSize(width: 1500, height: 1050))
        let clamped = MainWindowFramePolicy.zoomedContentSize(
            current: NSSize(width: 1200, height: 800),
            minimum: MainWindowFramePolicy.minimumSize(visibleFrame: visible, scale: 1.6),
            visible: NSSize(width: 1000, height: 700), from: 1, to: 1.6)
        #expect(clamped == NSSize(width: 1000, height: 700))
    }

    @Test func zoomOutKeepsTheScaledMinimum() {
        let minimum = NSSize(width: 768, height: 512)
        let next = MainWindowFramePolicy.zoomedContentSize(
            current: NSSize(width: 700, height: 400), minimum: minimum,
            visible: NSSize(width: 2000, height: 1400), from: 1, to: 0.8)
        #expect(next == NSSize(width: 768, height: 512))
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
