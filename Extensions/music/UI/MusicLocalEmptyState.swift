import EdithExtensionUI
import SwiftUI

enum EmbeddedMusicLocalEmpty: Equatable {
    case favourites
    case search(String)
    case emptyLibrary
    case emptyFolder

    static func resolve(search: String, showingFavourites: Bool, folderPath: String) -> Self {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { return .search(query) }
        if showingFavourites { return .favourites }
        return folderPath.isEmpty ? .emptyLibrary : .emptyFolder
    }
}

struct EmbeddedMusicLocalEmptyState: View {
    let kind: EmbeddedMusicLocalEmpty
    let folderLocation: String?
    let download: () -> Void
    let openLibrary: () -> Void
    let clearSearch: () -> Void
    let showFolders: () -> Void
    let goUp: () -> Void

    var body: some View {
        switch kind {
        case .favourites:
            PageEmptyState(
                icon: .heart,
                title: "No favourites yet",
                message:
                    "Tap the heart on any track and it shows up here, so your best songs are one click away.",
                primary: PageAction(
                    "Browse your music", icon: .playlist,
                    identifier: "music.empty.browse", perform: showFolders))
        case .search(let query):
            PageEmptyState(
                icon: .search,
                title: "Nothing matches \u{201C}\(query)\u{201D}",
                message:
                    "Check the spelling, try a shorter word, or search by artist or file name.",
                primary: PageAction(
                    "Clear search", icon: .closeFilled, identifier: "music.empty.clear",
                    perform: clearSearch))
        case .emptyLibrary:
            PageEmptyState(
                icon: .music,
                title: "Add music to start listening",
                message:
                    "Edith plays the audio files in your music folder. Save audio from YouTube, or copy your own files into the folder.",
                steps: [
                    PageGuideStep(
                        icon: .arrowDown, title: "Download audio",
                        detail: "Paste a YouTube link and Edith saves the audio here."),
                    PageGuideStep(
                        icon: .folder, title: "Add your own files",
                        detail: "Drop songs into the music folder in Finder."),
                    PageGuideStep(
                        icon: .play, title: "Press play",
                        detail: "Your tracks appear here and play in the menu bar too."),
                ],
                primary: PageAction(
                    "Download from YouTube", icon: .arrowDown,
                    identifier: "music.empty.download", perform: download),
                secondary: PageAction(
                    "Open music folder", icon: .folder, identifier: "music.empty.folder",
                    perform: openLibrary),
                footnote: folderLocation.map {
                    "Music folder: \($0). Added files in Finder? Press Rescan at the top."
                } ?? "Added files in Finder? Press Rescan at the top.")
        case .emptyFolder:
            PageEmptyState(
                icon: .folder,
                title: "This folder is empty",
                message:
                    "Move tracks here from another folder by dragging them onto this folder in the path bar, or download new audio.",
                primary: PageAction(
                    "Back to parent folder", icon: .chevronLeft,
                    identifier: "music.empty.up", perform: goUp),
                secondary: PageAction(
                    "Download from YouTube", icon: .arrowDown,
                    identifier: "music.empty.download", perform: download))
        }
    }
}
