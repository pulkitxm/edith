@_implementationOnly import EdithExtensionSupport_attention_native
@_implementationOnly import EdithExtensionUI_attention_native
import AppKit
import Foundation

enum AttentionExtensionInstaller {
    static let version = "2.0.3"

    static var bundledDirectory: URL? {
        AttentionResources.chromeExtension
    }

    static var installedDirectoryOverride: URL?
    static var installedDirectory: URL {
        installedDirectoryOverride
            ?? AttentionPaths.directory.appendingPathComponent("chrome-extension")
    }

    @discardableResult
    static func install() throws -> URL {
        guard let source = bundledDirectory else {
            throw AttentionExtensionInstallerError.missingBundle
        }
        let destination = installedDirectory
        let manager = FileManager.default
        try manager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.copyItem(at: source, to: destination)
        return destination
    }

    static var installedVersion: String? {
        let manifest = installedDirectory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifest),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["version"] as? String
    }

    @discardableResult
    static func refreshIfOutdated() -> Bool {
        guard FileManager.default.fileExists(atPath: installedDirectory.path),
            installedVersion != version
        else { return false }
        return (try? install()) != nil
    }

    static let browserBundleIDs = [
        "com.google.Chrome", "org.chromium.Chromium", "com.brave.Browser",
        "com.microsoft.edgemac", "com.operasoftware.Opera",
    ]
    static var revealDirectory: (URL) -> Void = {
        NSWorkspace.shared.activateFileViewerSelecting([$0])
    }
    static var applicationURL: (String) -> URL? = {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
    }
    static var openWithApplication: (URL, URL) -> Void = { url, app in
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [url], withApplicationAt: app, configuration: configuration, completionHandler: nil)
    }
    static var openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }

    static func reveal() throws {
        let directory = try install()
        revealDirectory(directory)
    }

    @discardableResult
    static func openExtensionsPage() -> Bool {
        guard let url = URL(string: "chrome://extensions") else { return false }
        for identifier in browserBundleIDs {
            guard let app = applicationURL(identifier) else { continue }
            openWithApplication(url, app)
            return true
        }
        return openURL(url)
    }
}

enum AttentionExtensionOperation: String, CaseIterable, Sendable {
    case install
    case open
    case token

    var descriptor: UserOperationDescriptor {
        switch self {
        case .install:
            descriptor(
                ["extension", "install"],
                "Install and reveal the attention browser extension.", .write)
        case .open:
            descriptor(
                ["extension", "open"], "Open the browser extensions page.", .interactive)
        case .token:
            descriptor(
                ["extension", "token"], "Print the attention browser setup token.", .read)
        }
    }

    var interfaceExposure: UserOperationExposure {
        switch self {
        case .install:
            userInterface("Attention setup", "install and reveal the browser extension")
        case .open:
            userInterface("Attention setup", "open the browser extensions page")
        case .token:
            userInterface("Attention setup", "copy the browser setup token")
        }
    }

    private func descriptor(_ path: [String], _ summary: String, _ effect: UserOperationEffect)
        -> UserOperationDescriptor
    {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "attention.extension.\(rawValue)"), summary: summary,
            cli: ["attention"] + path, effect: effect)
    }
}

private func userInterface(_ surface: String, _ action: String, _ exampleArguments: [String] = [])
    -> UserOperationExposure
{
    .userInterface([
        UserInterfaceActionPlacement(
            surface: surface, action: action, exampleArguments: exampleArguments)
    ])
}

enum AttentionExtensionInstallerError: LocalizedError {
    case missingBundle

    var errorDescription: String? {
        "The bundled browser extension could not be found."
    }
}
