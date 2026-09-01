import Darwin
import Foundation

public struct GhosttyResourceLocator {
    public typealias EnvironmentSetter = (String, String) -> Bool

    public static let environmentName = "GHOSTTY_RESOURCES_DIR"

    private let bundle: Bundle
    private let fileManager: FileManager

    public init(bundle: Bundle? = nil, fileManager: FileManager = .default) {
        self.bundle = bundle ?? .module
        self.fileManager = fileManager
    }

    public func bundledResourceDirectory() -> URL? {
        guard
            let root = bundle.resourceURL?.appendingPathComponent(
                "GhosttyResources", isDirectory: true)
        else { return nil }
        return resourceDirectory(in: root)
    }

    public func resourceDirectory(in root: URL) -> URL? {
        let ghostty = root.appendingPathComponent("ghostty", isDirectory: true)
        let shellIntegration = ghostty.appendingPathComponent(
            "shell-integration", isDirectory: true)
        let terminfo = root.appendingPathComponent("terminfo/78/xterm-ghostty")
        guard isDirectory(ghostty), isDirectory(shellIntegration), isFile(terminfo) else {
            return nil
        }
        return ghostty
    }

    @discardableResult
    public func configureEnvironment(
        from root: URL? = nil,
        setter: EnvironmentSetter = { name, value in
            name.withCString { key in
                value.withCString { setenv(key, $0, 1) == 0 }
            }
        }
    ) -> URL? {
        let directory: URL?
        if let root {
            directory = resourceDirectory(in: root)
        } else {
            directory = bundledResourceDirectory()
        }
        guard let directory, setter(Self.environmentName, directory.path) else { return nil }
        return directory
    }

    private func isDirectory(_ url: URL) -> Bool {
        var directory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &directory)
            && directory.boolValue
    }

    private func isFile(_ url: URL) -> Bool {
        var directory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &directory)
            && !directory.boolValue
    }
}
