import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

final class CleaningOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    init(screen: NSScreen, rootView: some View) {
        super.init(
            contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        isReleasedWhenClosed = false
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
    let store: KeyboardCleaning
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "keyboard.fill").font(.system(size: 52))
                if store.phase == .cleaning {
                    Text("Keyboard is off - clean away").font(.edithText(.title))
                    Text("Auto-restores in \(store.failsafeRemaining)s")
                        .font(.edithText(.callout)).foregroundStyle(.white.opacity(0.7))
                        .monospacedDigit()
                    Button("Done cleaning") { store.stopCleaning() }
                        .buttonStyle(.edith(.primary)).tint(themeColor(themeName)).controlSize(
                            .large)
                } else {
                    Text("Starting in \(store.armingCountdown)…").font(.edithText(.title))
                        .monospacedDigit()
                    Text("Move your hands away from the keyboard.").foregroundStyle(
                        .white.opacity(0.7))
                }
            }.foregroundStyle(.white).padding(40)
        }.preferredColorScheme(.dark)
    }
}
