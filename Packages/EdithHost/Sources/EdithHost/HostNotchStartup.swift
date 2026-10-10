import AppKit
import EdithHostCore
import Foundation

@MainActor
protocol HostNotchStartupLifecycle: AnyObject {
    func install()
    func owningWorkspaceChanged() async throws
    func stop() async throws
    func compactVersions(_ origin: HostNotchCompactOrigin) -> [String: String]?
    func window(for presentationID: UUID) -> NSWindow?
}

extension HostNotchLifecycleAdapter: HostNotchStartupLifecycle {}

@MainActor
struct HostNotchStartupContext {
    let association: HostNotchWindowAssociation
    let available: @MainActor () -> Bool
    let navigate: HostNotchCompactCardModel.Navigate
}

@MainActor
final class HostNotchStartup {
    private let navigation: HostWindowNavigation
    private var lifecycle: (any HostNotchStartupLifecycle)?
    private var refreshing: Task<Void, Never>?
    private var stopped = false
    private var generation = UUID()
    private(set) var failed = false

    init(
        navigation: HostWindowNavigation,
        make: (HostNotchStartupContext) -> any HostNotchStartupLifecycle
    ) {
        self.navigation = navigation
        let context = HostNotchStartupContext(
            association: .init(
                associate: { [weak self] window in
                    guard let self, !stopped, let owner = navigation.registeredMainWorkspace else {
                        throw HostWindowNavigationError.unavailable
                    }
                    return try navigation.associate(window: window, with: owner.window)
                }, remove: { [weak navigation] token in navigation?.removeAssociation(token) }),
            available: { [weak self] in
                guard let self, !stopped else { return false }
                return navigation.registeredMainWorkspace != nil
            },
            navigate: { [weak self] origin, provider, version in
                guard let self, !stopped,
                    lifecycle?.compactVersions(origin)?[provider] == version,
                    let window = lifecycle?.window(for: origin.cardPresentationID),
                    navigation.owningWorkspace(for: window) != nil
                else { throw HostWindowNavigationError.unavailable }
                try await navigation.navigate(
                    extensionID: provider, version: version,
                    presentationID: origin.cardPresentationID, location: "notch")
                guard !stopped, lifecycle?.compactVersions(origin)?[provider] == version,
                    lifecycle?.window(for: origin.cardPresentationID) === window,
                    navigation.owningWorkspace(for: window) != nil
                else { throw HostWindowNavigationError.routeRejected }
            })
        lifecycle = make(context)
        navigation.didChangeMainWorkspace = { [weak self] in self?.workspaceChanged() }
        lifecycle?.install()
        workspaceChanged()
    }

    convenience init(
        marketplace: HostMarketplace, manager: HostRemoteSessionManager,
        navigation: HostWindowNavigation
    ) {
        self.init(navigation: navigation) { context in
            HostNotchLifecycleAdapter(
                marketplace: marketplace, manager: manager, association: context.association,
                compactNavigate: context.navigate, owningWorkspaceAvailable: context.available)
        }
    }

    func window(for presentationID: UUID) -> NSWindow? {
        guard !stopped else { return nil }
        return lifecycle?.window(for: presentationID)
    }

    private func workspaceChanged() {
        guard !stopped else { return }
        let previous = refreshing
        let current = UUID()
        generation = current
        refreshing = Task { [weak self] in
            await previous?.value
            guard let self, !stopped, generation == current else { return }
            do { try await lifecycle?.owningWorkspaceChanged(); failed = false } catch {
                failed = true
            }
            if generation == current { refreshing = nil }
        }
    }

    func settled() async { await refreshing?.value }

    func stop() async throws {
        stopped = true
        generation = UUID()
        navigation.didChangeMainWorkspace = nil
        refreshing?.cancel()
        await refreshing?.value
        refreshing = nil
        try await lifecycle?.stop()
        failed = false
    }
}
