import Foundation

public struct CLIInstallResult: Equatable, Sendable {
    public var directory: String
    public var linked: [String]
    public var skipped: [String]
    public var message: String?

    public init(
        directory: String, linked: [String] = [], skipped: [String] = [], message: String? = nil
    ) {
        self.directory = directory
        self.linked = linked
        self.skipped = skipped
        self.message = message
    }
}

public enum CLIInstaller {
    public static let toolNames = ["ed", "edh", "edith"]
    public static let primaryTool = "ed"

    public static func bundledToolsDirectory(
        from bundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) -> URL? {
        var candidate: URL? = bundleURL
        for _ in 0..<6 {
            guard let current = candidate else { break }
            if fileManager.isExecutableFile(
                atPath: current.appendingPathComponent(primaryTool).path)
            {
                return current
            }
            let tools = current.appendingPathComponent("Contents/MacOS")
            if fileManager.isExecutableFile(
                atPath: tools.appendingPathComponent(primaryTool).path)
            {
                return tools
            }
            candidate = current.pathComponents.count > 1 ? current.deletingLastPathComponent() : nil
        }
        return nil
    }

    public static func preferredDirectory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL {
        let system = URL(fileURLWithPath: "/usr/local/bin")
        if fileManager.isWritableFile(atPath: system.path) { return system }
        return home.appendingPathComponent(".local/bin")
    }

    public static func pathEntries(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    }

    public static func isOnPath(_ directory: URL, entries: [String]) -> Bool {
        let target = directory.standardizedFileURL.path
        return entries.contains { URL(fileURLWithPath: $0).standardizedFileURL.path == target }
    }

    @discardableResult
    public static func install(
        toolsDirectory: URL? = nil,
        into directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> CLIInstallResult {
        guard let tools = toolsDirectory ?? bundledToolsDirectory(fileManager: fileManager) else {
            return CLIInstallResult(
                directory: "", message: "the ed binary is not present in this build")
        }
        let target = directory ?? preferredDirectory(fileManager: fileManager)
        try? fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        var result = CLIInstallResult(directory: target.path)
        for name in toolNames {
            let source = tools.appendingPathComponent(sourceName(for: name))
            guard fileManager.isExecutableFile(atPath: source.path) else {
                result.skipped.append(name)
                continue
            }
            let link = target.appendingPathComponent(name)
            let existing = try? fileManager.destinationOfSymbolicLink(atPath: link.path)
            if existing == source.path { continue }
            if fileManager.fileExists(atPath: link.path) || existing != nil {
                guard existing != nil || isOurs(link, fileManager: fileManager) else {
                    result.skipped.append(name)
                    continue
                }
                try? fileManager.removeItem(at: link)
            }
            do {
                try fileManager.createSymbolicLink(at: link, withDestinationURL: source)
                result.linked.append(name)
            } catch {
                result.skipped.append(name)
            }
        }
        return result
    }

    @discardableResult
    public static func uninstall(
        from directory: URL? = nil, fileManager: FileManager = .default
    ) -> CLIInstallResult {
        let target = directory ?? preferredDirectory(fileManager: fileManager)
        var result = CLIInstallResult(directory: target.path)
        for name in toolNames {
            let link = target.appendingPathComponent(name)
            guard (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil else {
                continue
            }
            try? fileManager.removeItem(at: link)
            result.linked.append(name)
        }
        return result
    }

    public static func installIfNeeded(fileManager: FileManager = .default) {
        guard let tools = bundledToolsDirectory(fileManager: fileManager) else { return }
        let target = preferredDirectory(fileManager: fileManager)
        let current = toolNames.compactMap {
            try? fileManager.destinationOfSymbolicLink(
                atPath: target.appendingPathComponent($0).path)
        }
        let wanted = toolNames.map { tools.appendingPathComponent(sourceName(for: $0)).path }
        if Set(current) != Set(wanted) {
            install(toolsDirectory: tools, into: target, fileManager: fileManager)
        }
        guard SharedDefaults.store.bool(forKey: CompletionScripts.autoRefreshKey) else { return }
        CompletionScripts.refreshInstalled(fileManager: fileManager)
    }

    static func sourceName(for name: String) -> String {
        name == "edh" ? "edh" : primaryTool
    }

    static func isOurs(_ link: URL, fileManager: FileManager) -> Bool {
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path)
        else { return false }
        return toolNames.contains((destination as NSString).lastPathComponent)
    }
}
