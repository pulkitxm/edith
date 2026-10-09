import Foundation

public enum CLIToolEnvironment {
    public static func sanitized(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        shellEnvironment: [String: String]? = UserShellEnvironment.shared.current(),
        fileManager: FileManager = .default
    ) -> [String: String] {
        var environment = processEnvironment
        for (key, value) in shellEnvironment ?? [:]
        where UserShellEnvironment.imports(key) && processEnvironment[key] == nil {
            environment[key] = value
        }
        environment.removeValue(forKey: "NO_COLOR")
        let directories = commonDirectories(
            processEnvironment: processEnvironment, fileManager: fileManager)
        let shellPath = shellEnvironment?["PATH"]?.split(separator: ":").map(String.init) ?? []
        let existing = processEnvironment["PATH"]?.split(separator: ":").map(String.init) ?? []
        environment["PATH"] = uniqueAllowedDirectories(
            directories.prefix(1) + shellPath + directories.dropFirst() + existing
        ).joined(separator: ":")
        return environment
    }

    public static func executable(
        named name: String,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        shellEnvironment: [String: String]? = UserShellEnvironment.shared.current(),
        fileManager: FileManager = .default
    ) -> URL? {
        let environment = sanitized(
            processEnvironment: processEnvironment, shellEnvironment: shellEnvironment,
            fileManager: fileManager)
        for directory in environment["PATH"]?.split(separator: ":").map(String.init) ?? [] {
            guard RestoredPathValidation.verdict(for: directory) == .keep else { continue }
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path),
                developerToolIsBacked(
                    candidate, processEnvironment: processEnvironment, fileManager: fileManager)
            {
                return candidate
            }
        }
        return nil
    }

    static let developerToolShims: Set<String> = ["git"]
    static let developerSelectionLink = "/var/db/xcode_select_link"
    static let defaultDeveloperDirectories = [
        "/Applications/Xcode.app/Contents/Developer", "/Library/Developer/CommandLineTools",
    ]

    static func developerToolIsBacked(
        _ candidate: URL, processEnvironment: [String: String], fileManager: FileManager,
        selectionLink: String = developerSelectionLink
    ) -> Bool {
        let name = candidate.lastPathComponent
        guard developerToolShims.contains(name),
            candidate.deletingLastPathComponent().standardizedFileURL.path == "/usr/bin"
        else { return true }
        let directories: [String]
        if let configured = processEnvironment["DEVELOPER_DIR"], !configured.isEmpty {
            directories = [configured]
        } else if let selected = try? fileManager.destinationOfSymbolicLink(atPath: selectionLink) {
            directories = [selected]
        } else {
            directories = defaultDeveloperDirectories
        }
        return directories.contains {
            fileManager.isExecutableFile(atPath: $0 + "/usr/bin/" + name)
        }
    }

    private static func commonDirectories(
        processEnvironment: [String: String], fileManager: FileManager
    ) -> [String] {
        let home = fileManager.homeDirectoryForCurrentUser
        var directories = [
            ExtensionData.root.appendingPathComponent("bin").path,
            home.appendingPathComponent(".local/bin").path,
            home.appendingPathComponent(".cargo/bin").path,
            home.appendingPathComponent(".nvm/current/bin").path,
            "/opt/homebrew/bin", "/usr/local/bin", "/Library/TeX/texbin", "/usr/bin", "/bin",
            "/usr/sbin", "/sbin",
        ]
        let nvmRoot = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? fileManager.contentsOfDirectory(
            at: nvmRoot, includingPropertiesForKeys: nil)
        {
            directories.insert(
                contentsOf: versions.sorted {
                    nodeVersionOrder($0.lastPathComponent, $1.lastPathComponent)
                }.map { $0.appendingPathComponent("bin").path }, at: 3)
        }
        if let configuredHome = processEnvironment["HOME"], !configuredHome.isEmpty {
            directories.insert(
                URL(fileURLWithPath: configuredHome).appendingPathComponent(".local/bin").path,
                at: 1)
        }
        return directories
    }

    static func nodeVersionOrder(_ lhs: String, _ rhs: String) -> Bool {
        let left = versionComponents(lhs)
        let right = versionComponents(rhs)
        guard left != right else { return lhs > rhs }
        return right.lexicographicallyPrecedes(left)
    }

    private static func versionComponents(_ name: String) -> [Int] {
        name.drop { !$0.isNumber }.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    private static func uniqueAllowedDirectories(_ directories: [String]) -> [String] {
        var seen = Set<String>()
        return directories.compactMap { directory in
            let standardized = URL(fileURLWithPath: directory).standardizedFileURL.path
            guard RestoredPathValidation.verdict(for: standardized) == .keep,
                seen.insert(standardized).inserted
            else { return nil }
            return standardized
        }
    }
}
