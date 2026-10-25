import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

private final class EmojiFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if MainActor.assumeIsolated({ TextEditingCommands.handle(event) }) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class EmojiPanel: NSObject, NSWindowDelegate {
    static let shared = EmojiPanel()

    static let width: CGFloat = 364
    static let height: CGFloat = 396
    static let willShow = Notification.Name("emojiPanelWillShow")
    static let didHide = Notification.Name("emojiPanelDidHide")

    weak var store: EmojiStore? {
        didSet {
            guard store !== oldValue else { return }
            if store == nil { hide() }
            mountRootView()
        }
    }

    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private var showTask: Task<Void, Never>?
    private var model: EmojiPanelModel?
    private var retiredModels: [UUID: Task<Void, Never>] = [:]
    private var showGeneration = 0
    private var stopped = false
    private var pendingShow: (PopupPosition, NSSize, Int)?
    private var showToken: UUID?
    private var positionJoin: Task<Void, Never>?
    private var callbackWork: [UUID: Task<Void, Never>] = [:]
    private var callbackKinds = Set<String>()

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard !stopped, store != nil, let panel else { return }
        NotificationCenter.default.post(name: Self.willShow, object: nil)
        panel.setContentSize(NSSize(width: Self.width, height: Self.height))
        let position = PopupPosition.stored(forKey: AppStorageKeys.Emoji.popupAt)
        let size = panel.frame.size
        showGeneration += 1
        let generation = showGeneration
        showTask?.cancel()
        pendingShow = (position, size, generation)
        startShow()
    }

    private func startShow() {
        guard !stopped, showTask == nil, let (position, size, generation) = pendingShow else {
            return
        }
        pendingShow = nil
        let token = UUID()
        showToken = token
        let task = Task.detached { [self] in
            let origin = await position.origin(size: size, statusItemFrame: nil, anchors: .emoji)
            let cancelled = Task.isCancelled
            await finishPosition(
                origin: origin, generation: generation, token: token, cancelled: cancelled)
        }
        showTask = task
        positionJoin = Task { [self, task] in
            await task.value
            guard showToken == token else { return }
            showTask = nil
            showToken = nil
            positionJoin = nil
            startShow()
        }
    }

    private func finishPosition(origin: NSPoint, generation: Int, token: UUID, cancelled: Bool) {
        guard showToken == token else { return }
        if !cancelled { finishShow(origin: origin, generation: generation) }
    }

    private func finishShow(origin: NSPoint, generation: Int) {
        guard !stopped, generation == showGeneration, let panel else { return }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        showGeneration += 1
        showTask?.cancel()
        pendingShow = nil
        panel?.orderOut(nil)
        NotificationCenter.default.post(name: Self.didHide, object: nil)
    }

    private func startCallback(_ kind: String, _ operation: @escaping @MainActor () -> Void) {
        guard !stopped, callbackKinds.insert(kind).inserted else { return }
        let id = UUID()
        callbackWork[id] = Task { [self] in
            defer { callbackWork[id] = nil; callbackKinds.remove(kind) }
            guard !stopped, !Task.isCancelled else { return }
            operation()
        }
    }

    func cancelPendingWork() {
        stopped = true
        hide()
        model?.stop()
        for task in callbackWork.values { task.cancel() }
    }

    func drain() async {
        cancelPendingWork()
        let model = model
        let pending = Array(callbackWork.values) + Array(retiredModels.values)
        await showTask?.value
        await positionJoin?.value
        await model?.stopAndWait()
        for task in pending { await task.value }
    }

    private func mountRootView() {
        if let model {
            model.stop()
            let id = UUID()
            retiredModels[id] = Task { [self, model] in
                await model.stopAndWait()
                retiredModels[id] = nil
            }
            self.model = nil
        }
        guard let store else {
            hosting?.rootView = AnyView(EmptyView())
            return
        }
        guard !stopped else { return }
        if panel == nil { makePanel() }
        let model = EmojiPanelModel(
            catalog: store.catalog, frequent: store.frequent, search: store.search)
        self.model = model
        hosting?.rootView = AnyView(
            EmojiPanelView(store: store, model: model, onDismiss: { [weak self] in self?.hide() })
                .themedControls())
        hosting?.layoutSubtreeIfNeeded()
    }

    private func makePanel() {
        let created = EmojiFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true
        created.level = .statusBar
        created.collectionBehavior = [
            .auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary,
        ]
        created.animationBehavior = .none
        created.isFloatingPanel = true
        created.hidesOnDeactivate = false
        created.isReleasedWhenClosed = false
        created.isMovableByWindowBackground = true
        created.delegate = self

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 9
        effect.layer?.masksToBounds = true

        let host = NSHostingView(rootView: AnyView(EmptyView()))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        created.contentView = effect
        hosting = host
        panel = created
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            startCallback("hide") { [self] in hide() }
        }
    }

    nonisolated func windowDidMove(_ notification: Notification) {
        MainActor.assumeIsolated {
            startCallback("move") { [self] in
                guard let panel = panel, panel.isVisible,
                    NSEvent.pressedMouseButtons & 1 == 1
                else { return }
                PopupPosition.saveLastPosition(
                    frame: panel.frame, screen: panel.screen, anchors: .emoji)
            }
        }
    }
}
