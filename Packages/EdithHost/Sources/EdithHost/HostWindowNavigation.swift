import AppKit
import EdithExtensionSupport
import Foundation
import SwiftUI

struct HostWindowRoute: Equatable {
    let page: String
    let section: String?
    let relativePath: String?
    let presentationID: UUID?
    let location: String?
}

enum HostWindowNavigationError: Error, Equatable {
    case unavailable
    case invalidDestination
    case inactiveOwner
    case routeRejected
}

@MainActor
final class HostWindowNavigation {
    typealias Apply = @MainActor (HostWindowRoute) async throws -> Void
    private let activeVersions: @MainActor () -> [String: String]
    private let defaults: UserDefaults
    private let originatingWindow: @MainActor (UUID) -> NSWindow?
    private let didApply: @MainActor (HostWindowRoute) async throws -> Void
    private var registrations: [UUID: Registration] = [:]
    private var sequence: UInt64 = 0

    init(
        defaults: UserDefaults = SharedDefaults.store,
        activeVersions: @escaping @MainActor () -> [String: String],
        originatingWindow: @escaping @MainActor (UUID) -> NSWindow? = { _ in nil },
        didApply: @escaping @MainActor (HostWindowRoute) async throws -> Void = { _ in }
    ) {
        self.defaults = defaults
        self.activeVersions = activeVersions
        self.originatingWindow = originatingWindow
        self.didApply = didApply
    }

    func register(
        window: NSWindow, apply: @escaping Apply, selected: @escaping @MainActor () -> String
    ) -> UUID {
        registrations = registrations.filter { $0.value.window != nil }
        sequence &+= 1
        let token = UUID()
        registrations[token] = Registration(
            window: window, order: sequence, apply: apply, selected: selected)
        return token
    }

    func unregister(_ token: UUID) { registrations[token] = nil }

    func navigate(
        extensionID: String, version: String, section: String? = nil,
        relativePath: String? = nil, presentationID: UUID? = nil, location: String? = nil
    ) async throws {
        try Task.checkCancellation()
        guard activeVersions()[extensionID] == version else {
            throw HostWindowNavigationError.inactiveOwner
        }
        guard let owned = HostNavigationCatalog.route(extensionID: extensionID) else {
            throw HostWindowNavigationError.invalidDestination
        }
        let page = section ?? owned.page
        guard page == owned.page || (extensionID == "music" && page == "downloads"),
            HostNavigationCatalog.pages.contains(where: { $0.id == page }),
            HostNavigationCatalog.visible(
                HostNavigationCatalog.page(page), active: Set(activeVersions().keys),
                defaults: defaults),
            location.map({
                [
                    "main", "settings", "home", "notch", "sidebar.utility", "music.footer",
                    "music.sidebar", "music.detail",
                ]
                .contains($0)
            }) ?? true,
            (presentationID == nil) == (location == nil),
            !(location?.hasPrefix("music.") ?? false) || extensionID == "music"
        else { throw HostWindowNavigationError.invalidDestination }
        if let relativePath {
            guard extensionID == "music", page == "music", relativePath.utf8.count <= 4096,
                !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.hasPrefix("~"),
                !relativePath.utf8.contains(0), !relativePath.contains("\\"),
                relativePath.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                    !$0.isEmpty && $0 != "." && $0 != ".."
                })
            else { throw HostWindowNavigationError.invalidDestination }
        }
        registrations = registrations.filter { $0.value.window != nil }
        let origin = presentationID.flatMap(originatingWindow)
        guard presentationID == nil || origin != nil else {
            throw HostWindowNavigationError.unavailable
        }
        let candidates = registrations.filter {
            $0.value.window?.identifier?.rawValue == "EdithMainWindow"
        }
        if let origin, origin.identifier?.rawValue == "EdithMainWindow",
            !candidates.contains(where: { $0.value.window === origin })
        {
            throw HostWindowNavigationError.unavailable
        }
        let chosen =
            candidates.first(where: { $0.value.window === origin })
            ?? candidates.first(where: { $0.value.window?.isKeyWindow == true })
            ?? candidates.max(by: { $0.value.order < $1.value.order })
        guard let (token, registration) = chosen else {
            throw HostWindowNavigationError.unavailable
        }
        let route = HostWindowRoute(
            page: page, section: page == owned.page ? owned.section : nil,
            relativePath: relativePath, presentationID: presentationID, location: location)
        try Task.checkCancellation()
        try await registration.apply(route)
        try Task.checkCancellation()
        guard activeVersions()[extensionID] == version else {
            throw HostWindowNavigationError.inactiveOwner
        }
        guard registrations[token] === registration, registration.window != nil,
            registration.selected() == route.page
        else { throw HostWindowNavigationError.routeRejected }
        try await didApply(route)
        try Task.checkCancellation()
        guard activeVersions()[extensionID] == version else {
            throw HostWindowNavigationError.inactiveOwner
        }
        guard registrations[token] === registration, registration.selected() == route.page,
            HostNavigationCatalog.visible(
                HostNavigationCatalog.page(page), active: Set(activeVersions().keys),
                defaults: defaults)
        else { throw HostWindowNavigationError.routeRejected }
    }

    private final class Registration {
        weak var window: NSWindow?
        let order: UInt64
        let apply: Apply
        let selected: @MainActor () -> String
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
