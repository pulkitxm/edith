import EdithCore
import Foundation

struct ChromeProfile: Identifiable, Equatable, Hashable, Sendable {
    let directory: String
    let name: String
    let email: String?
    let pictureURL: URL?
    let colorARGB: UInt32?

    var id: String { directory }

    var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" })
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }
}

struct ChromeUserData: Equatable, Sendable {
    let root: URL

    static let standardRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)

    static let standard = ChromeUserData(root: standardRoot)

    var localStateURL: URL { root.appendingPathComponent("Local State") }

    func directory(for profile: ChromeProfile) -> URL {
        root.appendingPathComponent(profile.directory, isDirectory: true)
    }

    func cookiesURL(for profile: ChromeProfile, fileManager: FileManager = .default) -> URL? {
        let base = directory(for: profile)
        let candidates = [
            base.appendingPathComponent("Network/Cookies"), base.appendingPathComponent("Cookies"),
        ]
        let existing = candidates.filter { fileManager.fileExists(atPath: $0.path) }
        return existing.max { modified($0, fileManager) < modified($1, fileManager) }
    }

    func localStorageURL(for profile: ChromeProfile) -> URL {
        directory(for: profile).appendingPathComponent("Local Storage/leveldb", isDirectory: true)
    }

    func profiles(fileManager: FileManager = .default) throws -> [ChromeProfile] {
        guard fileManager.fileExists(atPath: localStateURL.path) else { return [] }
        let data = try Data(contentsOf: localStateURL)
        return ChromeProfileParser.profiles(
            localState: data, root: root,
            exists: { fileManager.fileExists(atPath: $0.path) })
    }

    private func modified(_ url: URL, _ fileManager: FileManager) -> Date {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date ?? .distantPast
    }
}

enum ChromeProfileParser {
    static func profiles(localState: Data, root: URL, exists: (URL) -> Bool) -> [ChromeProfile] {
        guard
            let object = try? JSONSerialization.jsonObject(with: localState) as? [String: Any],
            let profile = object["profile"] as? [String: Any],
            let cache = profile["info_cache"] as? [String: [String: Any]]
        else { return [] }
        let order = (profile["profiles_order"] as? [String]) ?? []
        let directories =
            order.filter { cache[$0] != nil }
            + cache.keys.sorted(by: directoryOrder)
            .filter { !order.contains($0) }
        return directories.compactMap { directory in
            guard let info = cache[directory] else { return nil }
            let folder = root.appendingPathComponent(directory, isDirectory: true)
            guard exists(folder) else { return nil }
            return ChromeProfile(
                directory: directory, name: displayName(info, directory: directory),
                email: nonEmpty(info["user_name"]),
                pictureURL: picture(info, folder: folder, exists: exists),
                colorARGB: color(info))
        }
    }

    static func displayName(_ info: [String: Any], directory: String) -> String {
        let name = nonEmpty(info["name"])
        let given = nonEmpty(info["gaia_given_name"])
        let full = nonEmpty(info["gaia_name"])
        if info["is_using_default_name"] as? Bool == true, let given { return given }
        return name ?? full ?? given ?? directory
    }

    private static func picture(_ info: [String: Any], folder: URL, exists: (URL) -> Bool)
        -> URL?
    {
        var candidates: [URL] = []
        if let file = nonEmpty(info["gaia_picture_file_name"]) {
            candidates.append(folder.appendingPathComponent(file))
        }
        if let gaia = nonEmpty(info["gaia_id"]) {
            candidates.append(folder.appendingPathComponent("Accounts/Avatar Images/\(gaia)"))
        }
        candidates.append(folder.appendingPathComponent("Google Profile Picture.png"))
        return candidates.first(where: exists)
    }

    private static func color(_ info: [String: Any]) -> UInt32? {
        for key in ["profile_highlight_color", "default_avatar_fill_color"] {
            guard let number = info[key] as? NSNumber else { continue }
            return UInt32(truncatingIfNeeded: number.int64Value)
        }
        return nil
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        BlankText.trimmedNonEmpty(value)
    }

    private static func directoryOrder(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == "Default" { return rhs != "Default" }
        if rhs == "Default" { return false }
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}
