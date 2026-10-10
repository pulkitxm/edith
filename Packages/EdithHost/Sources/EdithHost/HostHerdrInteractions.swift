import AppKit
import EdithHostCore
import UserNotifications

@MainActor
final class HostHerdrInteractions {
    private let folderChoice: HostFolderChoiceCoordinator
    private let notifications: HostHerdrNotificationRouter
    private let bindDelegate: @MainActor (HostApplicationDelegate) -> (@MainActor () -> Void)
    private weak var delegate: HostApplicationDelegate?
    private var restoreDelegate: (@MainActor () -> Void)?

    init(
        folderChoice: HostFolderChoiceCoordinator, notifications: HostHerdrNotificationRouter,
        bindDelegate: @escaping @MainActor (HostApplicationDelegate) -> (@MainActor () -> Void) = {
            delegate in
            let center = UNUserNotificationCenter.current()
            let previous = center.delegate
            center.delegate = delegate
            return {
                if center.delegate === delegate { center.delegate = previous }
            }
        }
    ) {
        self.folderChoice = folderChoice
        self.notifications = notifications
        self.bindDelegate = bindDelegate
    }

    convenience init(
        marketplace: HostMarketplace, manager: HostRemoteSessionManager,
        presenter: HostRemoteContentPresenter, navigation: HostWindowNavigation,
        windows: HostHerdrWindows
    ) {
        let panel = HostFolderChoicePanel(
            manager: manager, presenter: presenter, navigation: navigation)
        let presentation = HostFolderChoicePresentation(
            manager: manager, presenter: presenter, navigation: navigation,
            readyWindow: { [weak presenter] in presenter?.herdrReadyWindow(for: $0) },
            currentOrigin: { [weak manager] request, registration in
                guard let manager else { throw HostWorkerError.rejected }
                return try manager.folderChoiceOrigin(request, windowRegistration: registration)
            })
        let folderChoice = HostFolderChoiceCoordinator(
            origin: { try presentation.origin($0) }, select: { try await panel.select($0) },
            cancelSelection: { panel.cancel($0) })
        let notifications = HostHerdrNotificationRouter(
            currentVersion: { [weak marketplace] in
                guard let marketplace, marketplace.surfaceAvailability.activeIDs.contains("herdr"),
                    !marketplace.pendingRemovalIDs.contains("herdr"),
                    !marketplace.sessions.pendingDisableIDs.contains("herdr")
                else { return nil }
                return marketplace.sessions.versions["herdr"]
            }, navigation: navigation,
            preparedPresentation: {
                [weak manager, weak presenter, weak navigation] version in
                guard let manager, let presenter, let navigation else {
                    throw HostWorkerError.rejected
                }
                let deadline = ContinuousClock.now + .seconds(5)
                while ContinuousClock.now < deadline {
                    try Task.checkCancellation()
                    if let workspace = navigation.registeredMainWorkspace,
                        workspace.window.isVisible, !workspace.window.isMiniaturized
                    {
                        let candidates = manager.herdrNotificationPresentations(version: version)
                            .filter { presenter.herdrReadyWindow(for: $0) === workspace.window }
                        if candidates.count == 1, let id = candidates.first {
                            return try manager.herdrNotificationLease(
                                presentationID: id, version: version,
                                validateWindow: {
                                    [
                                        weak navigation, weak presenter,
                                        weak window = workspace.window
                                    ] in
                                    guard let navigation, let presenter, let window,
                                        navigation.workspaceRegistration(for: window)
                                            == workspace.token,
                                        presenter.herdrReadyWindow(for: id) === window,
                                        navigation.owningWorkspace(for: window) === window,
                                        window.isVisible, !window.isMiniaturized
                                    else { throw HostWorkerError.rejected }
                                })
                        }
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                throw HostWorkerError.timedOut
            })
        self.init(folderChoice: folderChoice, notifications: notifications)
    }

    func install(delegate: HostApplicationDelegate) {
        restoreDelegate?()
        self.delegate = delegate
        delegate.notificationClick = { [weak self] request in
            guard let self else { throw HostWorkerError.rejected }
            try await self.notifications.receive(request)
        }
        restoreDelegate = bindDelegate(delegate)
    }

    func chooseFolder(_ request: HostWorkerNavigationRequest) async throws -> HostFolderChoiceResult
    {
        try await folderChoice.choose(request)
    }

    func cancelPending() async {
        await folderChoice.cancelAndWait()
        await notifications.cancelAndDrain()
    }

    func stop() async {
        await cancelPending()
        folderChoice.stop()
        notifications.stop()
        await notifications.drain()
        delegate?.notificationClick = nil
        restoreDelegate?()
        restoreDelegate = nil
        delegate = nil
    }
}
