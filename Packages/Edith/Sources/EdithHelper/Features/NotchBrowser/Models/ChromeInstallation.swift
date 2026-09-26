import AppKit
import Foundation

enum ChromeReadiness: Equatable, Sendable {
    case notInstalled
    case unreadable(String)
    case notDefault(currentBrowser: String?)
    case noProfiles
    case ready

    var allowsAttaching: Bool {
        switch self {
        case .ready, .notDefault: true
        case .notInstalled, .unreadable, .noProfiles: false
        }
    }
}

struct ChromeInstallation: Sendable {
    static let bundleIdentifier = "com.google.Chrome"
    static let downloadURL = URL(string: "https://www.google.com/chrome/")!
    static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    var applicationURL: @Sendable () -> URL?
    var defaultBrowser: @Sendable () -> (bundleIdentifier: String, name: String)?
    var userData: ChromeUserData

    static let live = ChromeInstallation(
        applicationURL: {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        },
        defaultBrowser: {
            guard let probe = URL(string: "https://example.com"),
                let app = NSWorkspace.shared.urlForApplication(toOpen: probe),
                let bundle = Bundle(url: app), let identifier = bundle.bundleIdentifier
            else { return nil }
            let name =
                FileManager.default.displayName(atPath: app.path)
                .replacingOccurrences(of: ".app", with: "")
            return (identifier, name)
        },
        userData: .standard)

    static func readiness(
        installed: Bool, defaultBrowser: (bundleIdentifier: String, name: String)?,
        profileCount: Int
    ) -> ChromeReadiness {
        guard installed else { return .notInstalled }
        guard profileCount > 0 else { return .noProfiles }
        guard defaultBrowser?.bundleIdentifier.lowercased() == bundleIdentifier.lowercased()
        else { return .notDefault(currentBrowser: defaultBrowser?.name) }
        return .ready
    }

    func inspect() -> (readiness: ChromeReadiness, profiles: [ChromeProfile]) {
        guard applicationURL() != nil else { return (.notInstalled, []) }
        let profiles: [ChromeProfile]
        do {
            profiles = try userData.profiles()
        } catch {
            return (.unreadable(error.localizedDescription), [])
        }
        let readiness = Self.readiness(
            installed: true, defaultBrowser: defaultBrowser(), profileCount: profiles.count)
        return (readiness, profiles)
    }

    @MainActor
    func makeDefaultBrowser(completion: @escaping @MainActor (Error?) -> Void) {
        guard let app = applicationURL() else {
            completion(CocoaError(.fileNoSuchFile))
            return
        }
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { error in
            Task { @MainActor in completion(error) }
        }
    }

    @MainActor
    func open(_ url: URL, profile: ChromeProfile?) {
        guard let app = applicationURL() else {
            NSWorkspace.shared.open(url)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        if let profile {
            configuration.createsNewApplicationInstance = true
            configuration.arguments = [
                "--profile-directory=\(profile.directory)", url.absoluteString,
            ]
            NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        } else {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
        }
    }
}
