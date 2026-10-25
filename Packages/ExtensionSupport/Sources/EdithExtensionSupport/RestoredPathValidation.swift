import Foundation

public enum RestoredPathVerdict: Equatable {
    case keep
    case drop
}

public enum RestoredPathValidation {
    public static func verdict(
        for path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> RestoredPathVerdict {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL
            .resolvingSymlinksInPath().path
        let homePath = homeDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        if standardizedPath == homePath || standardizedPath.hasPrefix(homePath + "/") {
            return .keep
        }
        if standardizedPath == "/Volumes" || standardizedPath.hasPrefix("/Volumes/") {
            return .drop
        }
        return .keep
    }
}
