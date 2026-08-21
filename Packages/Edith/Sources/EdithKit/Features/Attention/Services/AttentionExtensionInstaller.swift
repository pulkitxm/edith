import AppKit
import Foundation

public enum AttentionExtensionInstaller {
    public static var bundledDirectory: URL? {
        Bundle.module.url(forResource: "ChromeExtension", withExtension: nil)
    }

    public static var installedDirectory: URL {
        AttentionPaths.directory.appendingPathComponent("chrome-extension")
    }

    @discardableResult
    public static func install() throws -> URL {
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

    public static func reveal() throws {
        let directory = try install()
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }
}

public enum AttentionExtensionInstallerError: LocalizedError {
    case missingBundle

    public var errorDescription: String? {
        "The bundled browser extension could not be found."
    }
}
