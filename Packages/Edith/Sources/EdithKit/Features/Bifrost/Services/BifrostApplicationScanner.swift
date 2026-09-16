import Foundation

public enum BifrostApplicationScanner {
    public static let bundleExtension = "app"
    public static let maximumDepth = 3
    public static let maximumApplications = 4000

    public static var defaultRoots: [URL] {
        var roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications", isDirectory: true),
        ]
        roots.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true))
        return roots
    }

    public static func scan(
        roots: [URL], fileManager: FileManager = .default,
        readName: (URL) -> String? = displayName(at:)
    ) -> [BifrostApplication] {
        var found: [String: BifrostApplication] = [:]
        for root in roots {
            collect(root, depth: 0, fileManager: fileManager, readName: readName, into: &found)
            if found.count >= maximumApplications { break }
        }
        return found.values.sorted { first, second in
            if first.name != second.name { return first.name < second.name }
            return first.path < second.path
        }
    }

    private static func collect(
        _ directory: URL, depth: Int, fileManager: FileManager, readName: (URL) -> String?,
        into found: inout [String: BifrostApplication]
    ) {
        guard depth < maximumDepth, found.count < maximumApplications else { return }
        let contents = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        guard let contents else { return }
        for entry in contents {
            if entry.pathExtension == bundleExtension {
                guard found[entry.path] == nil else { continue }
                let name = readName(entry) ?? entry.deletingPathExtension().lastPathComponent
                found[entry.path] = BifrostApplication(
                    name: name, path: entry.path, bundleID: bundleIdentifier(at: entry))
                if found.count >= maximumApplications { return }
                continue
            }
            let isDirectory =
                (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else { continue }
            collect(
                entry, depth: depth + 1, fileManager: fileManager, readName: readName,
                into: &found)
        }
    }

    public static func displayName(at bundleURL: URL) -> String? {
        guard let info = Bundle(url: bundleURL)?.infoDictionary else { return nil }
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let value = info[key] as? String,
                !value.trimmingCharacters(in: .whitespaces).isEmpty
            {
                return value
            }
        }
        return nil
    }

    public static func bundleIdentifier(at bundleURL: URL) -> String? {
        Bundle(url: bundleURL)?.bundleIdentifier
    }
}
