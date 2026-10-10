import AppKit
import EdithHostCore
import Foundation

@MainActor
protocol HostNotchStartupLifecycle: AnyObject {
    func install()
    func owningWorkspaceChanged() async throws
    func stop() async throws
    func compactVersions(_ origin: HostNotchCompactOrigin) -> [String: String]?
    func navigationTicket(presentationID: UUID, providerID: String, version: String)
        -> HostNotchNavigationTicket?
    func collapseAfterAcknowledgement(_ ticket: HostNotchNavigationTicket) async throws
    func window(for presentationID: UUID) -> NSWindow?
}

extension HostNotchLifecycleAdapter: HostNotchStartupLifecycle {}

@MainActor
struct HostNotchStartupContext {
    let association: HostNotchWindowAssociation
    let available: @MainActor () -> Bool
    let navigate: HostNotchCompactCardModel.Navigate
    let postNavigation: HostNotchCompactCardModel.Navigate
}

@MainActor
final class HostNotchStartup {
    private let navigation: HostWindowNavigation
    private var lifecycle: (any HostNotchStartupLifecycle)?
    private var refreshing: Task<Void, Never>?
    private var stopped = false
    private var generation = UUID()
    private var navigating: Set<UUID> = []
    private var compactAcknowledgements: [UUID: HostNotchNavigationTicket] = [:]
    private var acknowledged: [HostNotchNavigationTicket] = []
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
                guard let self, !stopped else { throw HostWindowNavigationError.unavailable }
                compactAcknowledgements = compactAcknowledgements.filter { _, ticket in
                    lifecycle?.navigationTicket(
                        presentationID: ticket.presentationID, providerID: ticket.providerID,
                        version: ticket.providerVersion) == ticket
                }
                guard navigating.count < 8,
                    !navigating.contains(origin.cardPresentationID),
                    (compactAcknowledgements[origin.cardPresentationID] != nil
                        || compactAcknowledgements.count < 8),
                    let ticket = navigationTicket(
                        presentationID: origin.cardPresentationID, providerID: provider,
                        version: version),
                    lifecycle?.compactVersions(origin)?[provider] == version,
                    let window = lifecycle?.window(for: origin.cardPresentationID),
                    let owner = navigation.owningWorkspace(for: window)
                else { throw HostWindowNavigationError.unavailable }
                navigating.insert(origin.cardPresentationID)
                defer { navigating.remove(origin.cardPresentationID) }
                try await navigation.navigate(
                    extensionID: provider, version: version,
                    presentationID: origin.cardPresentationID, location: "notch")
                guard !stopped, lifecycle?.compactVersions(origin)?[provider] == version,
                    lifecycle?.window(for: origin.cardPresentationID) === window,
                    navigation.owningWorkspace(for: window) === owner,
                    navigationTicket(
                        presentationID: origin.cardPresentationID, providerID: provider,
                        version: version) == ticket
                else { throw HostWindowNavigationError.routeRejected }
                compactAcknowledgements[origin.cardPresentationID] = ticket
            },
            postNavigation: { [weak self] origin, provider, version in
                guard let self,
                    let ticket = compactAcknowledgements.removeValue(
                        forKey: origin.cardPresentationID),
                    ticket.identity == origin.identity, ticket.displayID == origin.displayID,
                    ticket.panelPresentationID == origin.panelPresentationID,
                    ticket.slot.tile == origin.tile, ticket.providerID == provider,
                    ticket.providerVersion == version
                else { throw HostWindowNavigationError.routeRejected }
                try await navigationAcknowledged(ticket)
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
                compactNavigate: context.navigate,
                compactNavigationAcknowledged: context.postNavigation,
                owningWorkspaceAvailable: context.available)
        }
    }

    func window(for presentationID: UUID) -> NSWindow? {
        guard !stopped else { return nil }
        return lifecycle?.window(for: presentationID)
    }

    func navigationTicket(presentationID: UUID, providerID: String, version: String)
        -> HostNotchNavigationTicket?
    {
        guard !stopped, let window = lifecycle?.window(for: presentationID),
            navigation.owningWorkspace(for: window) != nil
        else { return nil }
        return lifecycle?.navigationTicket(
            presentationID: presentationID, providerID: providerID, version: version)
    }

    func navigationAcknowledged(_ ticket: HostNotchNavigationTicket) async throws {
        try Task.checkCancellation()
        guard !stopped, !acknowledged.contains(ticket), let lifecycle,
            lifecycle.navigationTicket(
                presentationID: ticket.presentationID, providerID: ticket.providerID,
                version: ticket.providerVersion) == ticket,
            let window = lifecycle.window(for: ticket.presentationID),
            navigation.owningWorkspace(for: window) != nil
        else { throw HostWindowNavigationError.routeRejected }
        acknowledged.append(ticket)
        if acknowledged.count > 32 { acknowledged.removeFirst() }
        try await lifecycle.collapseAfterAcknowledgement(ticket)
    }

    private func workspaceChanged() {
        guard !stopped else { return }
        compactAcknowledgements.removeAll()
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
        compactAcknowledgements.removeAll()
        generation = UUID()
        navigation.didChangeMainWorkspace = nil
        refreshing?.cancel()
        await refreshing?.value
        refreshing = nil
        try await lifecycle?.stop()
        failed = false
    }
}
