import AppKit
import EdithKit
import SwiftUI

final class KeystrokeHighlightPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen, rootView: some View) {
        super.init(
            contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hasShadow = false
        animationBehavior = .none
        collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
        ]
        contentView = NSHostingView(rootView: rootView)
        setFrame(screen.frame, display: true)
    }
}

struct KeystrokeHighlightOverlay: View {
    let runtime: KeystrokeHighlightRuntime
    @AppStorage(AppStorageKeys.KeystrokeHighlight.position, store: SharedDefaults.store) private
        var position = KeystrokeHighlightPosition.bottom.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if resolvedPosition == .bottom { Spacer(minLength: 0) }
            HStack(alignment: .bottom, spacing: 14) {
                ForEach(runtime.entries) { entry in
                    KeystrokeHighlightEntryView(entry: entry)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .asymmetric(
                                    insertion: .scale(scale: 0.84).combined(with: .opacity),
                                    removal: .move(
                                        edge: resolvedPosition == .top ? .top : .bottom
                                    ).combined(with: .opacity)))
                }
            }
            .padding(.horizontal, 36)
            .animation(
                reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.76),
                value: runtime.entries)
            if resolvedPosition == .top { Spacer(minLength: 0) }
        }
        .padding(.top, 72)
        .padding(.bottom, 72)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
    }

    private var resolvedPosition: KeystrokeHighlightPosition {
        KeystrokeHighlightPosition(rawValue: position) ?? .bottom
    }
}

private struct KeystrokeHighlightEntryView: View {
    let entry: KeystrokeHighlightEntry

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(entry.keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.96))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .padding(.horizontal, key.count > 2 ? 15 : 10)
                    .frame(minWidth: 44, minHeight: 46)
                    .background(
                        Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.94),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.32), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.7), radius: 0, y: 4)
                    .shadow(color: .black.opacity(0.32), radius: 14, y: 7)
            }
        }
        .padding(.bottom, 4)
    }
}
