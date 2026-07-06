import AppKit
import EdithKit
import SwiftUI

final class CleaningOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    init(screen: NSScreen, rootView: some View) {
        super.init(
            contentRect: screen.frame, styleMask: [.borderless],
            backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hasShadow = false
        contentView = NSHostingView(rootView: rootView)
        setFrame(screen.frame, display: true)
    }
}

struct CleaningOverlayView: View {
    @ObservedObject var store: SystemStore
    @AppStorage("theme", store: SharedDefaults.store) private var themeName = "accent"

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "keyboard.fill")
                    .font(.system(size: 52))
                if store.phase == .cleaning {
                    Text("Keyboard is off - clean away")
                        .font(.title)
                    Text("Auto-restores in \(store.failsafeRemaining)s")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                        .monospacedDigit()
                    Button("Done cleaning") {
                        store.stopCleaning()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(themeColor(themeName))
                    .controlSize(.large)
                    .pointerCursor()
                } else {
                    Text("Starting in \(store.armingCountdown)…")
                        .font(.title)
                        .monospacedDigit()
                    Text("Move your hands away from the keyboard.")
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .foregroundStyle(.white)
            .padding(40)
        }
        .preferredColorScheme(.dark)
    }
}
