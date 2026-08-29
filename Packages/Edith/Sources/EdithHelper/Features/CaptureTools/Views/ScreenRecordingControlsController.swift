import AppKit
import EdithKit
import SwiftUI

@MainActor
final class ScreenRecordingControlsController {
    private let panel: NSPanel

    init(
        source: ScreenRecordingSource, pause: @escaping () -> Void,
        stop: @escaping () -> Void, cancel: @escaping () -> Void
    ) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 310, height: 64),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ScreenRecordingControlsView(
            source: source, pause: pause, stop: stop, cancel: cancel))
    }

    func show() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(
            x: screen.visibleFrame.midX - frame.width / 2,
            y: screen.visibleFrame.minY + 24))
        panel.orderFrontRegardless()
    }

    func close() {
        panel.close()
        panel.contentView = nil
    }
}

private struct ScreenRecordingControlsView: View {
    let source: ScreenRecordingSource
    let pause: () -> Void
    let stop: () -> Void
    let cancel: () -> Void
    @State private var startedAt = Date()
    @State private var paused = false
    @State private var pauseStarted: Date?
    @State private var pausedDuration: TimeInterval = 0

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(.red).frame(width: 10, height: 10)
            TimelineView(.periodic(from: .now, by: 0.2)) { context in
                Text(elapsed(at: context.date), format: .time(pattern: .minuteSecond))
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .frame(width: 52)
            }
            Text(source.displayName).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button {
                if paused {
                    if let pauseStarted { pausedDuration += Date().timeIntervalSince(pauseStarted) }
                    pauseStarted = nil
                } else {
                    pauseStarted = Date()
                }
                paused.toggle()
                pause()
            } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill")
            }
            .help(paused ? "Resume" : "Pause")
            Button(action: stop) { Image(systemName: "stop.fill").foregroundStyle(.red) }
                .help("Stop and edit")
            Button(action: cancel) { Image(systemName: "xmark") }.help("Cancel recording")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .frame(height: 58)
        .background(.ultraThickMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.18)))
    }

    private func elapsed(at date: Date) -> Duration {
        let pausedNow = pauseStarted.map { date.timeIntervalSince($0) } ?? 0
        return .seconds(max(0, date.timeIntervalSince(startedAt) - pausedDuration - pausedNow))
    }
}
