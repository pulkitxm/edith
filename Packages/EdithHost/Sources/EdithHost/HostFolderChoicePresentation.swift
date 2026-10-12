import AppKit
import EdithHostCore

@MainActor
final class HostFolderChoicePresentation {
    private let manager: HostRemoteSessionManager
    private let presenter: HostRemoteContentPresenter
    private let navigation: HostWindowNavigation
    private let readyWindow: @MainActor (UUID) -> NSWindow?
    private let currentOrigin:
        @MainActor (HostWorkerNavigationRequest, UUID) throws -> HostFolderChoiceOrigin

    init(
        manager: HostRemoteSessionManager, presenter: HostRemoteContentPresenter,
        navigation: HostWindowNavigation, readyWindow: @escaping @MainActor (UUID) -> NSWindow?,
        currentOrigin:
            @escaping @MainActor (HostWorkerNavigationRequest, UUID) throws ->
            HostFolderChoiceOrigin
    ) {
        self.manager = manager; self.presenter = presenter; self.navigation = navigation
        self.readyWindow = readyWindow
        self.currentOrigin = currentOrigin
    }

    func origin(_ request: HostWorkerNavigationRequest) throws -> HostFolderChoiceOrigin {
        try manager.validateNavigationOrigin(request)
        guard let id = request.presentationID, let owner = readyWindow(id),
            presenter.window(for: id) === owner,
            owner.identifier?.rawValue == "EdithMainWindow", owner.isVisible, !owner.isMiniaturized,
            navigation.owningWorkspace(for: owner) === owner,
            let registration = navigation.workspaceRegistration(for: owner)
        else { throw HostWorkerError.rejected }
        let result = try currentOrigin(request, registration)
        try result.validate(request)
        guard result.windowRegistration == registration else { throw HostWorkerError.rejected }
        return result
    }
}
