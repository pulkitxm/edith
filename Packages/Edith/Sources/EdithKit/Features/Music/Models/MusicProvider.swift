import Foundation

public enum MusicProvider: String, CaseIterable, Identifiable, Sendable {
    case local, spotify, youtubeMusic

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .local: "Local music"
        case .spotify: "Spotify"
        case .youtubeMusic: "YouTube Music"
        }
    }

    public var symbol: String {
        switch self {
        case .local: "folder"
        case .spotify: "waveform.circle"
        case .youtubeMusic: "play.circle"
        }
    }

    public var homeURL: URL? {
        switch self {
        case .local: nil
        case .spotify: URL(string: "https://open.spotify.com/")
        case .youtubeMusic: URL(string: "https://music.youtube.com/")
        }
    }

    public static func spotifyURI(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces: [String]
        if value.hasPrefix("spotify:") {
            pieces = value.components(separatedBy: ":")
            guard pieces.count == 3 else { return nil }
        } else {
            guard let url = URL(string: value), url.scheme == "https",
                url.host == "open.spotify.com",
                url.user == nil, url.password == nil, url.port == nil
            else { return nil }
            var path = url.pathComponents.filter { $0 != "/" }
            if path.first?.hasPrefix("intl-") == true { path.removeFirst() }
            guard path.count == 2 else { return nil }
            pieces = ["spotify"] + path
        }
        guard ["track", "album", "playlist", "episode"].contains(pieces[1]),
            pieces[2].utf8.count == 22,
            pieces[2].utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            })
        else { return nil }
        return pieces.joined(separator: ":")
    }
}
