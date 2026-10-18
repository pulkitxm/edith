import EdithHostCore
import ExtensionMarketplace
import Foundation

struct HostWindowRoute: Equatable {
    let page: String
    let section: String?
    let relativePath: String?
    let presentationID: UUID?
    let location: String?
    var restoreOnly = false
    var settingsExtensionID: String? = nil
}

enum HostWindowNavigationError: Error, Equatable {
    case unavailable
    case invalidDestination
    case inactiveOwner
    case routeRejected
}

enum HostWorkerNavigationRouting {
    static func validateApplied(
        extensionID: String, version: String, activeVersions: [String: String], current: Bool,
        windowPresented: Bool = true, visible: Bool = true
    ) throws {
        guard activeVersions[extensionID] == version else {
            throw HostWindowNavigationError.inactiveOwner
        }
        guard current, windowPresented, visible else {
            throw HostWindowNavigationError.routeRejected
        }
    }

    static func activeVersions(
        installed: [String: ExtensionPackage], states: [String: HostActivationState],
        versions: [String: String], pendingDisable: Set<String>, pendingRemoval: Set<String>,
        systemVersion: ExtensionSystemVersion = .init(
            ProcessInfo.processInfo.operatingSystemVersion)
    ) -> [String: String] {
        versions.filter { id, version in
            guard let package = installed[id], package.id == id, package.version == version,
                states[id] == .active, !pendingDisable.contains(id), !pendingRemoval.contains(id)
            else { return false }
            return package.isCompatible(
                hostABI: HostContract.compatibility, architecture: "arm64",
                systemVersion: systemVersion)
        }
    }

    static func resolve(
        extensionID: String, version: String, section: String? = nil,
        relativePath: String? = nil, presentationID: UUID? = nil, location: String? = nil,
        activeVersions: [String: String], currentPage: String = "home", visible: (String) -> Bool
    ) throws -> HostWindowRoute {
        guard activeVersions[extensionID] == version else {
            throw HostWindowNavigationError.inactiveOwner
        }
        let owned: (page: String, section: String?)
        let restoreOnly = ["micMute", "bifrost"].contains(extensionID)
        let settingsID = ["clipboard", "emoji"].contains(extensionID) ? extensionID : nil
        switch extensionID {
        case "clipboard", "emoji": owned = ("extensions", nil)
        case "micMute", "bifrost": owned = (currentPage, nil)
        case "systemStats": owned = ("system", nil)
        default:
            guard let catalog = HostNavigationCatalog.route(extensionID: extensionID) else {
                throw HostWindowNavigationError.invalidDestination
            }
            owned = catalog
        }
        guard !restoreOnly || section == nil else {
            throw HostWindowNavigationError.invalidDestination
        }
        let page = section ?? owned.page
        guard page == owned.page || (extensionID == "music" && page == "downloads"),
            HostNavigationCatalog.pages.contains(where: { $0.id == page }),
            visible(page),
            location.map({
                [
                    "main", "settings", "home", "notch", "sidebar.utility", "music.footer",
                    "music.sidebar", "music.detail", "machines.window",
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
        return HostWindowRoute(
            page: page, section: page == owned.page ? owned.section : nil,
            relativePath: relativePath, presentationID: presentationID, location: location,
            restoreOnly: restoreOnly, settingsExtensionID: settingsID)
    }
}
