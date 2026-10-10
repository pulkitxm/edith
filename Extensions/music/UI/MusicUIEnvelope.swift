import Foundation

struct EmbeddedMusicUIFolderIntent: Codable, Equatable, Sendable {
    var revision: UInt64
    var path: String
}

struct EmbeddedMusicUIQuery: Codable, Equatable, Sendable {
    var path = ""
    var search = ""
    var cursor = 0
}

struct EmbeddedMusicUIEntry: Codable, Equatable, Sendable {
    var path: String
    var url: URL
}

struct EmbeddedMusicUIPlayback: Codable, Equatable, Sendable {
    var path: String?
    var playing: Bool
    var elapsed: Double
    var duration: Double
    var volume: Double
    var shuffle: Bool
    var repeating: Bool
}

struct EmbeddedMusicUIState: Codable, Sendable {
    var root: URL
    var tracks: [EmbeddedMusicUIEntry]
    var folders: [EmbeddedMusicUIEntry]
    var folderTracks: [EmbeddedMusicUIEntry]
    var searchTracks: [EmbeddedMusicUIEntry]
    var searchFolders: [EmbeddedMusicUIEntry]
    var favourites: [EmbeddedMusicUIEntry]
    var playback: EmbeddedMusicUIPlayback
    var selected: String
    var spotify: EmbeddedMusicUIStreaming
    var youtubeConnecting: Bool
    var youtubeError: String?
    var youtubeConnected: Bool
    var restorePending: Int
    var events: [EmbeddedMusicUIEvent]
    var cursor: Int
    var privacy: Bool
    var folderIntent: EmbeddedMusicUIFolderIntent?
    var preferences = EmbeddedMusicUIPreferences()
    var tools = EmbeddedMusicUITools()
    func validate() throws {
        let numbers = [
            playback.elapsed, playback.duration, playback.volume, spotify.elapsed, spotify.duration,
            spotify.volume, preferences.fadeLength,
        ]
        guard root.isFileURL, numbers.allSatisfy({ $0.isFinite && $0 >= 0 }),
            (0...1).contains(playback.volume), (0...1).contains(spotify.volume),
            (0.5...8).contains(preferences.fadeLength),
            tracks.count <= 50_000, folders.count <= 50_000, events.count <= 64,
            ["local", "spotify", "youtubeMusic"].contains(selected), cursor >= 0
        else { throw CocoaError(.validationMissingMandatoryProperty) }
        if let folderIntent {
            guard folderIntent.revision > 0 else {
                throw CocoaError(.validationMissingMandatoryProperty)
            }
            try EmbeddedMusicUIAction(kind: .openMusic, path: folderIntent.path).validate()
        }
        for entry in tracks + folders + folderTracks + searchTracks + searchFolders + favourites {
            try EmbeddedMusicUIAction(kind: .startTrack, path: entry.path).validate()
            guard entry.url.isFileURL else { throw CocoaError(.validationMissingMandatoryProperty) }
        }
    }

}

struct EmbeddedMusicUIStreaming: Codable, Sendable {
    var connected: Bool
    var connecting: Bool
    var account: String
    var title: String
    var uri: String
    var artist: String
    var album: String
    var artworkURL: URL?
    var playing: Bool
    var elapsed: Double
    var duration: Double
    var volume: Double
    var error: String?
    var hasSavedAccount: Bool = false
    var disconnecting: Bool = false
}

enum EmbeddedMusicUIActionKind: String, Codable, CaseIterable, Sendable {
    case playPause, pause, resume, next, previous, seek, volume, shuffle, repeating
    case startTrack, startFolder, startFavourites, favourite
    case createFolder, move, rename, delete, renameFolder, deleteFolder
    case chooseLibrary, openLibrary, reveal, revealFolder, openDownloads, openMusic, openSource,
        selectProvider
    case connectSpotify, disconnectSpotify, cancelSpotify
    case connectYoutube, disconnectYoutube, reloadYoutube, openChrome
    case videoOpen, videoClose
    case crossfade, fadeLength, barCollapsed, barAutoHide, gridView, installTool, refreshTools
}

struct EmbeddedMusicUIAction: Codable, Sendable {
    var kind: EmbeddedMusicUIActionKind
    var path = ""
    var target = ""
    var value: Double?

    func validate() throws {
        guard path.utf8.count <= 4096, target.utf8.count <= 4096,
            value == nil || value!.isFinite,
            !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
            !path.contains("\0"), !target.contains("\0")
        else { throw CocoaError(.validationMissingMandatoryProperty) }
    }
}

struct EmbeddedMusicUIEvent: Codable, Sendable {
    var sequence: Int
    var data: Data
}

struct EmbeddedMusicUIProfile: Codable, Identifiable, Sendable {
    var id: String
    var name: String
}

struct EmbeddedMusicUIFrameRequest: Codable, Sendable {
    var width: Double
    var height: Double
}

struct EmbeddedMusicUIPreferences: Codable, Sendable {
    var crossfade = true
    var fadeLength = 2.0
    var barCollapsed = false
    var barAutoHide = false
    var gridView = false
}

struct EmbeddedMusicUITools: Codable, Sendable {
    var installed: Set<String> = []
    var installing: String?
    var error: String?
}
