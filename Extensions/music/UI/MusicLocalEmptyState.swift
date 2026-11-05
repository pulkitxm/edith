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
                symbolName: "heart",
                title: "No favourites yet",
                message:
                    "Tap the heart on any track and it shows up here, so your best songs are one click away.",
                primary: PageAction(
                    "Browse your music", symbolName: "music.note.list",
                    identifier: "music.empty.browse", perform: showFolders))
        case .search(let query):
            PageEmptyState(
                symbolName: "magnifyingglass",
                title: "Nothing matches \u{201C}\(query)\u{201D}",
                message:
                    "Check the spelling, try a shorter word, or search by artist or file name.",
                primary: PageAction(
                    "Clear search", symbolName: "xmark.circle", identifier: "music.empty.clear",
                    perform: clearSearch))
        case .emptyLibrary:
            PageEmptyState(
                symbolName: "music.note.house",
                title: "Add music to start listening",
                message:
                    "Edith plays the audio files in your music folder. Save audio from YouTube, or copy your own files into the folder.",
                steps: [
                    PageGuideStep(
                        symbolName: "arrow.down.circle", title: "Download audio",
                        detail: "Paste a YouTube link and Edith saves the audio here."),
                    PageGuideStep(
                        symbolName: "folder", title: "Or add your files",
                        detail: "Drop songs into the music folder in Finder."),
                    PageGuideStep(
                        symbolName: "play.fill", title: "Press play",
                        detail: "Your tracks appear here and play in the menu bar too."),
                ],
                primary: PageAction(
                    "Download from YouTube", symbolName: "arrow.down.circle",
                    identifier: "music.empty.download", perform: download),
                secondary: PageAction(
                    "Open music folder", symbolName: "folder", identifier: "music.empty.folder",
                    perform: openLibrary),
                footnote: folderLocation.map {
                    "\($0). Added files in Finder? Use the rescan button above."
                } ?? "Added files in Finder? Use the rescan button above.")
        case .emptyFolder:
            PageEmptyState(
                symbolName: "folder",
                title: "This folder is empty",
                message:
                    "Move tracks here from another folder by dragging them onto this folder in the path bar, or download new audio.",
                primary: PageAction(
                    "Back to parent folder", symbolName: "chevron.left",
                    identifier: "music.empty.up", perform: goUp),
                secondary: PageAction(
                    "Download from YouTube", symbolName: "arrow.down.circle",
                    identifier: "music.empty.download", perform: download))
        }
    }
}
