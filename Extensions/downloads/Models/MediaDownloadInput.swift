import Foundation

public enum DownloadBrowser: String, Codable, CaseIterable, Sendable {
    case safari, chrome, firefox, brave, edge
}

public enum MediaDownloadInput {
    public static func isValid(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            && !(url.host ?? "").isEmpty && url.user == nil && url.password == nil
            && !url.absoluteString.contains(where: { $0.isWhitespace || $0.isNewline })
    }

    public static func defaultDirectory(for kind: DownloadKind) -> URL {
        if kind == .audio { return DownloadsStorage.audioDirectory }
        let home =
            ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Downloads/Edith", isDirectory: true)
    }

    public static func isDirectImage(_ url: URL) -> Bool {
        ["jpg", "jpeg", "png", "gif", "webp", "avif", "heic", "tiff", "bmp"]
            .contains(url.pathExtension.lowercased())
    }
}
