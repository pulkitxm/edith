import AppKit
import EdithHostCore

@MainActor
final class HostFolderChoicePresentation {
    private final class WindowIdentity {
        weak var window: NSWindow?
        let token = UUID()
        init(window: NSWindow) { self.window = window }
    }

    private let manager: HostRemoteSessionManager
    private let presenter: HostRemoteContentPresenter
    private let navigation: HostWindowNavigation
    private let currentOrigin:
        @MainActor (HostWorkerNavigationRequest, UUID) throws -> HostFolderChoiceOrigin
    private var identities: [ObjectIdentifier: WindowIdentity] = [:]

    init(
        manager: HostRemoteSessionManager, presenter: HostRemoteContentPresenter,
        navigation: HostWindowNavigation,
        currentOrigin:
            @escaping @MainActor (HostWorkerNavigationRequest, UUID) throws ->
            HostFolderChoiceOrigin
    ) {
        self.manager = manager; self.presenter = presenter; self.navigation = navigation
        self.currentOrigin = currentOrigin
    }

    func origin(_ request: HostWorkerNavigationRequest) throws -> HostFolderChoiceOrigin {
        try manager.validateNavigationOrigin(request)
        guard let id = request.presentationID, let owner = presenter.window(for: id),
            owner.identifier?.rawValue == "EdithMainWindow", owner.isVisible, !owner.isMiniaturized,
            navigation.owningWorkspace(for: owner) === owner
        else { throw HostWorkerError.rejected }
        identities = identities.filter { $0.value.window != nil }
        let key = ObjectIdentifier(owner)
        let identity = identities[key] ?? WindowIdentity(window: owner)
        identities[key] = identity
        let result = try currentOrigin(request, identity.token)
        try result.validate(request)
        guard result.windowRegistration == identity.token else { throw HostWorkerError.rejected }
        return result
    }
}
