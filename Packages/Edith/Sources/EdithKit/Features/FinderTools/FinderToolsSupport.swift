import Foundation
import UniformTypeIdentifiers

public enum FinderToolsImageType: Equatable, Sendable {
    case png
    case image(String)

    public var identifier: String {
        switch self {
        case .png: "public.png"
        case let .image(identifier): identifier
        }
    }
}

public enum FinderToolsSupport {
    public static func enabled(
        _ key: String, defaults: UserDefaults = SharedDefaults.store, fallback: Bool = true
    ) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    public static func preferredImageType(in identifiers: [String]) -> FinderToolsImageType? {
        guard !identifiers.contains(UTType.fileURL.identifier) else { return nil }
        if identifiers.contains(UTType.png.identifier) { return .png }
        guard
            let identifier = identifiers.first(where: {
                UTType($0)?.conforms(to: .image) == true
            })
        else { return nil }
        return .image(identifier)
    }

    public static func focusedRoleAllowsRename(_ role: String?) -> Bool {
        guard let role else { return false }
        return !["AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField"].contains(role)
    }

    public static func imageFileName(at date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "Pasted Image %04d-%02d-%02d at %02d.%02d.%02d.png",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0,
            parts.minute ?? 0, parts.second ?? 0)
    }

    public static func uniqueImageURL(
        named name: String, in directory: URL, fileExists: (String) -> Bool
    ) -> URL {
        let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: name).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var index = 2
        while fileExists(candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(index).\(ext)")
            index += 1
        }
        return candidate
    }

    public static func moveDestination(
        for source: URL, in directory: URL, fileExists: (String) -> Bool
    ) -> URL? {
        let source = source.standardizedFileURL
        let directory = directory.standardizedFileURL
        guard source.isFileURL, directory.isFileURL, source != directory else { return nil }
        let destination = directory.appendingPathComponent(source.lastPathComponent)
            .standardizedFileURL
        if destination == source { return source }
        guard !fileExists(destination.path), !contains(directory, inside: source) else {
            return nil
        }
        return destination
    }

    public static func diskImageURL(mountedAt mountURL: URL, hdiutilInfo: Data) -> URL? {
        guard
            let root = try? PropertyListSerialization.propertyList(
                from: hdiutilInfo, options: [], format: nil) as? [String: Any],
            let images = root["images"] as? [[String: Any]]
        else { return nil }
        let mountPath = normalizedPath(mountURL.path)
        let matches = images.compactMap { image -> String? in
            guard let path = image["image-path"] as? String, path.hasPrefix("/"),
                let entities = image["system-entities"] as? [[String: Any]],
                entities.contains(where: {
                    guard let value = $0["mount-point"] as? String else { return false }
                    return normalizedPath(value) == mountPath
                })
            else { return nil }
            return path
        }
        guard Set(matches).count == 1, let path = matches.first else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return url.pathExtension.caseInsensitiveCompare("dmg") == .orderedSame ? url : nil
    }

    public static func applicationDestination(
        for application: URL, applicationsDirectory: URL
    ) -> URL? {
        let name = application.lastPathComponent
        guard application.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
            !name.hasPrefix("."),
            !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        let root = applicationsDirectory.standardizedFileURL
        let destination = root.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        return destination.deletingLastPathComponent() == root ? destination : nil
    }

    public static func displayName(preferred: String?, application: URL) -> String {
        let fallback = application.deletingPathExtension().lastPathComponent
        let trimmed = preferred?.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed?.isEmpty == false ? trimmed! : fallback
        let words = source.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let scalars = words.joined(separator: " ").unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                && !CharacterSet.illegalCharacters.contains($0)
        }
        let result = String(String.UnicodeScalarView(scalars).prefix(80))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? fallback : result
    }

    private static func contains(_ directory: URL, inside source: URL) -> Bool {
        let sourcePath = source.resolvingSymlinksInPath().path
        let directoryPath = directory.resolvingSymlinksInPath().path
        return directoryPath == sourcePath || directoryPath.hasPrefix(sourcePath + "/")
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
