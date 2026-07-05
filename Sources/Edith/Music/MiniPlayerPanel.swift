import AppKit
import Combine
import SwiftUI

@MainActor
final class MiniPanel {
    static let shared = MiniPanel()

    weak var services: AppServices?
    var tab = UserDefaults.standard.string(forKey: "tab") ?? "usage"
    var showSettings = false

    private var panel: NSPanel?
    private var hosting: NSHostingView<MiniPlayerDetached>?
    private var subscription: AnyCancellable?
    private var observedPlayer: MusicPlayer?
    private var shown = false
    private var lastParentFrame: NSRect?
    private var lastFrameChange = Date.distantPast
    private var retryScheduled = false

    func expectResize() {
        lastFrameChange = Date()
    }

    private let height: CGFloat = 64
    private let gap: CGFloat = 10

    func sync() {
        let player = services?.music
        if observedPlayer !== player {
            observedPlayer = player
            subscription = player?.objectWillChange.sink { _ in
                Task { @MainActor in MiniPanel.shared.sync() }
            }
        }
        let parent = NSApp.windows.first {
            $0.className.contains("MenuBarExtraWindow") && $0.isVisible
        }
        if let parent {
            if let last = lastParentFrame, last != parent.frame {
                lastFrameChange = Date()
            }
            lastParentFrame = parent.frame
        } else {
            lastParentFrame = nil
        }
        let wantsVisible =
            parent != nil
            && player?.current != nil
            && (tab != "music" || showSettings)
        if wantsVisible, let parent, let player {
            if !shown, Date().timeIntervalSince(lastFrameChange) < 0.3 {
                scheduleRetry()
                return
            }
            present(below: parent, player: player)
        } else {
            hide()
        }
    }

    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            Task { @MainActor in
                MiniPanel.shared.retryScheduled = false
                MiniPanel.shared.sync()
            }
        }
    }

    private func present(below parent: NSWindow, player: MusicPlayer) {
        let p = panel ?? makePanel(player: player)
        hosting?.rootView = MiniPlayerDetached(player: player)

        let target = NSRect(
            x: parent.frame.minX,
            y: parent.frame.minY - height - gap,
            width: parent.frame.width,
            height: height)

        p.level = parent.level
        p.collectionBehavior = parent.collectionBehavior
        if parent.childWindows?.contains(p) != true {
            parent.addChildWindow(p, ordered: .above)
        }
        if !shown {
            p.setFrame(target.offsetBy(dx: 0, dy: height * 0.6), display: false)
            p.alphaValue = 0
            p.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().setFrame(target, display: true)
                p.animator().alphaValue = 1
            }
            shown = true
        } else {
            p.setFrame(target, display: true)
            if !p.isVisible {
                p.alphaValue = 1
                p.orderFront(nil)
            }
        }
    }

    private func hide() {
        guard shown, let p = panel else { return }
        shown = false
        let tucked = p.frame.offsetBy(dx: 0, dy: height * 0.6)
        NSAnimationContext.runAnimationGroup(
            { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                p.animator().setFrame(tucked, display: true)
                p.animator().alphaValue = 0
            },
            completionHandler: {
                Task { @MainActor in
                    guard !MiniPanel.shared.shown else { return }
                    p.parent?.removeChildWindow(p)
                    p.orderOut(nil)
                }
            })
    }

    private func makePanel(player: MusicPlayer) -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.becomesKeyOnlyIfNeeded = true
        p.isMovable = false

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true

        let host = NSHostingView(rootView: MiniPlayerDetached(player: player))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        p.contentView = effect
        hosting = host
        panel = p
        return p
    }
}

struct MiniPlayerDetached: View {
    @ObservedObject var player: MusicPlayer
    @AppStorage("theme") private var themeName = "accent"

    var body: some View {
        MiniPlayer(player: player, theme: themeColor(themeName))
            .background {
                if let track = player.current {
                    AmbientGlow(track: track, player: player)
                        .animation(.easeInOut(duration: 0.6), value: track.id)
                }
            }
            .background(DetachedBackground())
    }
}

private struct DetachedBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        (scheme == .dark ? Color.black.opacity(0.55) : Color.white.opacity(0.45))
            .ignoresSafeArea()
    }
}
