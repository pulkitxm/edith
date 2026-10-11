import AppKit
import EdithExtensionSupport
import Foundation
import SwiftUI

@MainActor
final class HostWindowNavigation {
    typealias Apply = @MainActor (HostWindowRoute) async throws -> Void
    private let activeVersions: @MainActor () -> [String: String]
    private let defaults: UserDefaults
    private let originatingWindow: @MainActor (UUID) -> NSWindow?
    private let openWorkspace: @MainActor () throws -> Void
    private let showWindow: @MainActor (NSWindow) async throws -> Void
    private let windowIsPresented: @MainActor (NSWindow) -> Bool
    private let didApply: @MainActor (HostWindowRoute) async throws -> Void
    private var registrations: [UUID: Registration] = [:]
    private var sequence: UInt64 = 0
    private var publishedWorkspaceToken: UUID?
    var didChangeMainWorkspace: (@MainActor () -> Void)?

    var registeredMainWorkspace: (token: UUID, window: NSWindow)? {
        guard
            let selected = registrations.filter({
                $0.value.window?.identifier?.rawValue == "EdithMainWindow"
            }).max(by: { $0.value.order < $1.value.order }), let window = selected.value.window
        else { return nil }
        return (selected.key, window)
    }

    init(
        defaults: UserDefaults = SharedDefaults.store,
        activeVersions: @escaping @MainActor () -> [String: String],
        originatingWindow: @escaping @MainActor (UUID) -> NSWindow? = { _ in nil },
        openWorkspace: @escaping @MainActor () throws -> Void = {
            throw HostWindowNavigationError.unavailable
        },
        showWindow: @escaping @MainActor (NSWindow) async throws -> Void = { _ in },
        windowIsPresented: @escaping @MainActor (NSWindow) -> Bool = { _ in true },
        didApply: @escaping @MainActor (HostWindowRoute) async throws -> Void = { _ in }
    ) {
        self.defaults = defaults
        self.activeVersions = activeVersions
        self.originatingWindow = originatingWindow
        self.openWorkspace = openWorkspace
        self.showWindow = showWindow
        self.windowIsPresented = windowIsPresented
        self.didApply = didApply
    }

    func register(
        window: NSWindow, apply: @escaping Apply, selected: @escaping @MainActor () -> String
    ) -> UUID {
        registrations = registrations.filter { $0.value.window != nil }
        sequence &+= 1
        let token = UUID()
        let registration = Registration(
            window: window, order: sequence, apply: apply, selected: selected)
        registrations[token] = registration
        registration.closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self, weak window] notice in
            guard notice.object as? NSWindow === window else { return }
            MainActor.assumeIsolated {
                guard let self, let window, self.registrations[token]?.window === window
                else { return }
                self.unregister(token)
            }
        }
        publishWorkspaceChange()
        return token
    }

    private var relationships: [UUID: WindowRelationship] = [:]

    func owningWorkspace(for window: NSWindow) -> NSWindow? {
        let owner =
            window.identifier?.rawValue == "EdithMainWindow"
            ? window : relationships.values.first(where: { $0.window === window })?.owner
        guard let owner, registrations.values.contains(where: { $0.window === owner }) else {
            return nil
        }
        return owner
    }

    func workspaceRegistration(for window: NSWindow) -> UUID? {
        guard window.identifier?.rawValue == "EdithMainWindow" else { return nil }
        return registrations.filter { $0.value.window === window }
            .max(by: { $0.value.order < $1.value.order })?.key
    }

    func associate(window: NSWindow, with owner: NSWindow) throws -> UUID {
        guard relationships.values.allSatisfy({ $0.window !== window }), window !== owner,
            registrations.values.contains(where: { $0.window === owner }),
            owner.identifier?.rawValue == "EdithMainWindow"
        else { throw HostWindowNavigationError.unavailable }
        let token = UUID()
        relationships = relationships.filter { $0.value.window != nil && $0.value.owner != nil }
        relationships[token] = WindowRelationship(window: window, owner: owner)
        return token
    }

    func removeAssociation(_ token: UUID) { relationships[token] = nil }

    private func publishWorkspaceChange() {
        let current = registeredMainWorkspace?.token
        guard current != publishedWorkspaceToken else { return }
        publishedWorkspaceToken = current
        didChangeMainWorkspace?()
    }

    func unregister(_ token: UUID) {
        registrations[token] = nil
        publishWorkspaceChange()
    }

    func navigate(
        extensionID: String, version: String, section: String? = nil,
        relativePath: String? = nil, presentationID: UUID? = nil, location: String? = nil
    ) async throws {
        try Task.checkCancellation()
        let route = try HostWorkerNavigationRouting.resolve(
            extensionID: extensionID, version: version, section: section,
            relativePath: relativePath, presentationID: presentationID, location: location,
            activeVersions: activeVersions(),
            visible: {
                HostNavigationCatalog.visible(
                    HostNavigationCatalog.page($0), active: Set(activeVersions().keys),
                    defaults: defaults)
            })
        registrations = registrations.filter { $0.value.window != nil }
        let origin = presentationID.flatMap(originatingWindow)
        guard presentationID == nil || origin != nil else {
            throw HostWindowNavigationError.unavailable
        }
        let relationship = origin.flatMap { source in
            relationships.values.first(where: { $0.window === source })
        }
        let owner = origin.flatMap { source in
            source.identifier?.rawValue == "EdithMainWindow" ? source : relationship?.owner
        }
        guard origin == nil || owner != nil else { throw HostWindowNavigationError.unavailable }
        if origin == nil, registeredMainWorkspace == nil {
            try openWorkspace()
            for _ in 0..<100 {
                try Task.checkCancellation()
                try HostWorkerNavigationRouting.validateApplied(
                    extensionID: extensionID, version: version, activeVersions: activeVersions(),
                    current: true,
                    visible: HostNavigationCatalog.visible(
                        HostNavigationCatalog.page(route.page), active: Set(activeVersions().keys),
                        defaults: defaults))
                if registeredMainWorkspace != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        let candidates = registrations.filter {
            $0.value.window?.identifier?.rawValue == "EdithMainWindow"
        }
        let chosen: (key: UUID, value: Registration)?
        if let owner {
            chosen = candidates.first(where: { $0.value.window === owner })
        } else {
            chosen =
                candidates.first(where: { $0.value.window?.isKeyWindow == true })
                ?? candidates.max(by: { $0.value.order < $1.value.order })
        }
        guard let (token, registration) = chosen, let window = registration.window else {
            throw HostWindowNavigationError.unavailable
        }
        try Task.checkCancellation()
        try await registration.apply(route)
        try Task.checkCancellation()
        try HostWorkerNavigationRouting.validateApplied(
            extensionID: extensionID, version: version, activeVersions: activeVersions(),
            current: currentOrigin(presentationID, window: origin, relationship: relationship)
                && registrations[token] === registration && registration.window != nil
                && registration.selected() == route.page)
        try await showWindow(window)
        try Task.checkCancellation()
        try HostWorkerNavigationRouting.validateApplied(
            extensionID: extensionID, version: version, activeVersions: activeVersions(),
            current: currentOrigin(presentationID, window: origin, relationship: relationship)
                && registrations[token] === registration && registration.window === window
                && registration.selected() == route.page,
            windowPresented: windowIsPresented(window))
        try await didApply(route)
        try Task.checkCancellation()
        try HostWorkerNavigationRouting.validateApplied(
            extensionID: extensionID, version: version, activeVersions: activeVersions(),
            current: currentOrigin(presentationID, window: origin, relationship: relationship)
                && registrations[token] === registration && registration.window === window
                && registration.selected() == route.page,
            windowPresented: windowIsPresented(window),
            visible: HostNavigationCatalog.visible(
                HostNavigationCatalog.page(route.page), active: Set(activeVersions().keys),
                defaults: defaults))
    }

    private func currentOrigin(_ id: UUID?, window: NSWindow?, relationship: WindowRelationship?)
        -> Bool
    {
        guard let id else { return true }
        guard let window, originatingWindow(id) === window else { return false }
        if window.identifier?.rawValue == "EdithMainWindow" { return true }
        guard let relationship else { return false }
        return relationships.values.contains { $0 === relationship }
            && relationship.window === window && relationship.owner != nil
    }

    private final class WindowRelationship {
        weak var window: NSWindow?
        weak var owner: NSWindow?
        init(window: NSWindow, owner: NSWindow) { self.window = window; self.owner = owner }
    }

    private final class Registration {
        weak var window: NSWindow?
        let order: UInt64
        let apply: Apply
        let selected: @MainActor () -> String
        var closeObserver: NSObjectProtocol?
        deinit {
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        }
        init(
            window: NSWindow, order: UInt64, apply: @escaping Apply,
            selected: @escaping @MainActor () -> String
        ) {
            self.window = window; self.order = order; self.apply = apply; self.selected = selected
        }
    }
}

struct HostWindowNavigationAnchor: NSViewRepresentable {
    let navigation: HostWindowNavigation
    let apply: HostWindowNavigation.Apply
    let selected: @MainActor () -> String
    func makeNSView(context: Context) -> HostWindowNavigationView {
        HostWindowNavigationView(navigation: navigation, apply: apply, selected: selected)
    }
    func updateNSView(_ view: HostWindowNavigationView, context: Context) {
        view.apply = apply; view.selected = selected
    }
    static func dismantleNSView(_ view: HostWindowNavigationView, coordinator: ()) {
        view.detach()
    }
}

@MainActor
final class HostWindowNavigationView: NSView {
    private weak var navigation: HostWindowNavigation?
    private var token: UUID?
    var apply: HostWindowNavigation.Apply
    var selected: @MainActor () -> String
    init(
        navigation: HostWindowNavigation, apply: @escaping HostWindowNavigation.Apply,
        selected: @escaping @MainActor () -> String
    ) {
        self.navigation = navigation; self.apply = apply; self.selected = selected
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        detach()
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, let navigation else { return }
        token = navigation.register(
            window: window,
            apply: { [weak self] route in
                guard let self else { throw HostWindowNavigationError.unavailable }
                try await apply(route)
            },
            selected: { [weak self] in self?.selected() ?? "" })
    }
    func detach() {
        if let token { navigation?.unregister(token) }
        token = nil
    }
}
