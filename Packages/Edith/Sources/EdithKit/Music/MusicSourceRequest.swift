import Foundation

public enum MusicSourceRequest: Equatable, Sendable {
    case folder(String)
    case directory(String)
    case favourites
    case all

    public static let kindKey = "sourceKind"
    public static let pathKey = "sourcePath"

    public var kind: String {
        switch self {
        case .folder: return "folder"
        case .directory: return "directory"
        case .favourites: return "favourites"
        case .all: return "all"
        }
    }

    public var path: String {
        switch self {
        case let .folder(path), let .directory(path): return path
        case .favourites, .all: return ""
        }
    }

    public var payload: [String: Any] {
        var info: [String: Any] = [Self.kindKey: kind]
        if !path.isEmpty { info[Self.pathKey] = path }
        return info
    }

    public static func decode(_ info: [AnyHashable: Any]) -> MusicSourceRequest? {
        guard let kind = info[kindKey] as? String else { return nil }
        let path = info[pathKey] as? String ?? ""
        switch kind {
        case "folder": return .folder(path)
        case "directory": return .directory(path)
        case "favourites": return .favourites
        case "all": return .all
        default: return nil
        }
    }
}
