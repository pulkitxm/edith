import Foundation

public enum ClipboardCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case text, link, email, color, image, media, file

    public var id: String { rawValue }

    public init(_ entry: ClipboardEntry) {
        switch entry.kind {
        case .image: self = .image
        case .media: self = .media
        case .file, .document, .data: self = .file
        case .text, .richText, .html: self = Self.classify(text: entry.preview ?? "")
        }
    }

    public var title: String {
        switch self {
        case .text: "Text"
        case .link: "Links"
        case .email: "Emails"
        case .color: "Colors"
        case .image: "Images"
        case .media: "Media"
        case .file: "Files"
        }
    }

    public var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .email: "envelope"
        case .color: "paintpalette"
        case .image: "photo"
        case .media: "play.rectangle"
        case .file: "doc"
        }
    }

    public static func classify(text: String) -> ClipboardCategory {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 2048 else { return .text }
        if ClipboardColorValue(parsing: value) != nil { return .color }
        guard !value.contains(where: \.isWhitespace) else { return .text }
        if isEmail(value) { return .email }
        if isLink(value) { return .link }
        return .text
    }

    private static let linkSchemes: Set<String> = [
        "http", "https", "ftp", "ftps", "sftp", "ssh", "git", "ws", "wss",
    ]

    private static func isLink(_ value: String) -> Bool {
        if value.lowercased().hasPrefix("www.") { return isDomain(value.dropFirst(4)) }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
            linkSchemes.contains(scheme)
        else { return false }
        return url.host?.isEmpty == false
    }

    private static func isEmail(_ value: String) -> Bool {
        if value.lowercased().hasPrefix("mailto:") {
            let address = value.dropFirst(7).split(separator: "?", maxSplits: 1).first ?? ""
            return isAddress(address)
        }
        return isAddress(Substring(value))
    }

    private static func isAddress(_ value: Substring) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].count <= 64 else { return false }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: ".!#$%&'*+/=?^_`{|}~-"))
        guard parts[0].unicodeScalars.allSatisfy(allowed.contains),
            !parts[0].hasPrefix("."), !parts[0].hasSuffix(".")
        else { return false }
        return isDomain(parts[1])
    }

    private static func isDomain(_ value: Substring) -> Bool {
        let host = value.split(separator: "/", maxSplits: 1).first ?? ""
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let top = labels.last, top.count >= 2,
            top.allSatisfy(\.isLetter)
        else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return labels.allSatisfy { label in
            !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.unicodeScalars.allSatisfy(allowed.contains)
        }
    }
}
