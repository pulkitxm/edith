import AppKit
import EdithHostCore
@preconcurrency import ExtensionKit

@MainActor
final class HostNotchSceneLease {
    let request: HostExtensionContentRequest
    let controller: NSViewController
    private let update: @MainActor (Bool, Bool, Double) -> Void
    private let release: @MainActor () async throws -> Void
    private var closing: Task<Void, any Error>?
    private(set) var closed = false
    var measuredHeight: (@MainActor (Double) -> Void)?

    init(
        request: HostExtensionContentRequest, controller: NSViewController,
        update: @escaping @MainActor (Bool, Bool, Double) -> Void,
        release: @escaping @MainActor () async throws -> Void
    ) {
        self.request = request
        self.controller = controller
        self.update = update
        self.release = release
        if let remote = controller as? HostRemoteViewController {
            remote.changed = { [weak self, weak remote] in
                guard let height = remote?.contentHeight else { return }
                self?.measuredHeight?(height)
            }
        }
    }

    func apply(compact: Bool, visible: Bool, width: Double) {
        guard !closed else { return }
        update(compact, visible, width)
    }

    func detach() {
        (controller as? HostRemoteViewController)?.detach()
        if controller.isViewLoaded { controller.view.removeFromSuperview() }
        controller.removeFromParent()
    }

    func close() async throws {
        detach()
        guard !closed else { return }
        let task: Task<Void, any Error>
        if let closing {
            task = closing
        } else {
            task = Task { try await release() }
            closing = task
        }
        do {
            try await task.value
            closed = true
            closing = nil
        } catch {
            closing = nil
            throw error
        }
    }

    static func remote(
        manager: HostRemoteSessionManager, request: HostExtensionContentRequest
    ) async throws -> HostNotchSceneLease {
        let handle = try await manager.scene(for: request)
        do {
            let remote = EXHostViewController()
            remote.configuration = .init(
                appExtension: handle.identity, sceneID: handle.sceneIdentifier)
            let controller = HostRemoteViewController(
                request: request, remote: remote,
                connect: { connection, state, receive in
                    try await handle.connect(
                        through: connection, compact: state.compact, visible: state.visible,
                        width: state.width, receive: receive)
                },
                update: { state in
                    try await handle.update(
                        compact: state.compact, visible: state.visible, width: state.width)
                })
            return HostNotchSceneLease(
                request: request, controller: controller,
                update: { controller.apply(compact: $0, visible: $1, width: $2) },
                release: { try await manager.endPresentation(id: request.presentationID) })
        } catch {
            try await manager.endPresentation(id: request.presentationID)
            throw error
        }
    }
}
