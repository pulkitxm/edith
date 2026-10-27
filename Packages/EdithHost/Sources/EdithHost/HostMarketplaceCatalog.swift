import EdithHostCore
import Foundation

struct HostMarketplaceSuite: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    var defaultsKey: String { "suite" + id.capitalized + "Enabled" }
}

enum HostMarketplaceCatalog {
    static let suites: [HostMarketplaceSuite] = [
        .init(
            id: "agents", title: "Agents & Terminal",
            subtitle: "Run and review coding agents, track their limits, and reach your machines.",
            symbol: "sparkles"),
        .init(
            id: "utilities", title: "Mac Utilities",
            subtitle: "Updates, disk cleanup, sleep control, menu bar stats and your calendar.",
            symbol: "switch.2"),
        .init(
            id: "desk", title: "Desk",
            subtitle: "Hotkey tools: the launcher, clipboard, pickers, the notch and focus.",
            symbol: "hand.tap"),
        .init(
            id: "media", title: "Media",
            subtitle: "Edit files, record your screen, style your camera, play and save media.",
            symbol: "play.rectangle.on.rectangle"),
        .init(
            id: "developer", title: "Developer & Data",
            subtitle: "Databases, code growth, site audits, LaTeX and where your time goes.",
            symbol: "cylinder.split.1x2"),
        .init(
            id: "labs", title: "Labs",
            subtitle: "Experiments and visual toys. Hidden from the main list.",
            symbol: "flask"),
    ]
    static let hiddenByDefault: Set<String> = ["labs"]
    static let subtitles: [String: String] = [
        "usage": "See Claude, Codex and Cursor limits and usage, with alerts before you run out.",
        "herdr": "Start, watch and talk to coding agents on this Mac and your SSH machines.",
        "quinjet": "Review pull requests and live workspace changes in a native terminal.",
        "companion": "Your notes, voice memos and activity, remembered and searchable.",
        "plugins": "Install Edith skills into your coding agents.",
        "machines":
            "Add Macs and Linux servers over SSH, then open terminals, files and services on them.",
        "terminal": "Native terminal tabs for this Mac. Machines opens them on SSH hosts.",
        "docs": "Browse the ed command reference and ask how to do something.",
        "appMaintenance": "Install, update and cleanly remove apps, with a full history.",
        "homebrew": "Manage Homebrew formulae, casks and taps.",
        "cleaner": "Find reclaimable space across your drives and remove it after review.",
        "blitztree": "See what fills your disk as a treemap with the largest files.",
        "system": "See running apps and lock the keyboard while you clean it.",
        "keepAwake": "Keep the Mac and display awake until you turn it off.",
        "lidAwake": "Keep the Mac running with the lid closed, even on battery.",
        "systemStats": "Live CPU and memory in the menu bar.",
        "micMute": "Mute every microphone with ⌘⇧M or the menu bar icon.",
        "presenter": "Blur sensitive numbers while you share your screen.",
        "calendar": "Your schedule in the panel and the app.",
        "bifrost": "One bar to open any app, do quick sums and convert units.",
        "clipboard": "Clipboard history with instant paste.",
        "emoji": "Every emoji on a hotkey, typed into the app you are using.",
        "colorPicker": "Pick any color on screen and copy it.",
        "keystrokeHighlight": "Show key presses on screen for demos and recordings.",
        "focusDim": "Dim everything behind the app you are using.",
        "notchShelf": "A file shelf, now playing, camera and alerts around the notch.",
        "audioMixer": "Set the volume of each app from the notch.",
        "studio": "Edit, convert, compress and combine images, PDFs, video and audio.",
        "timeLapse": "Record displays or windows with audio, or capture a time-lapse.",
        "virtualCamera": "Frame, zoom and style your camera, then pick Edith Camera in any call.",
        "music": "Play local music, Spotify or YouTube Music.",
        "downloads": "Save videos, images and social posts with a download queue.",
        "socialManager": "Keep separate website accounts side by side in one window.",
        "database": "Explore databases and run guarded production changes.",
        "codeStats": "Mirror your GitHub repositories and see how your code grows.",
        "seoAudit": "Crawl sitemaps and check page metadata, all locally.",
        "latex": "Compile LaTeX documents locally or edit them on GitHub with review.",
        "attention": "See where your time goes and protect focused work.",
        "hinge": "Fold the desktop away as the MacBook lid closes.",
        "windowSweaters": "Knitted borders around your windows in each app's colors.",
        "jev": "Quick typed yes or no decisions from the Jev model.",
    ]
    static func providers(_ entries: [HostExtension] = (try? HostIndex.bundled()) ?? []) -> [String:
        Set<
            String
        >]
    {
        Dictionary(grouping: entries, by: \.category).mapValues { Set($0.map(\.id)) }
    }
    static func filter(_ entries: [HostExtension], query: String, category: String)
        -> [HostExtension]
    {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            (!query.isEmpty || entry.category == category
                || (category == "all" && !hiddenByDefault.contains(entry.category)))
                && (query.isEmpty || entry.title.localizedCaseInsensitiveContains(query)
                    || (subtitles[entry.id] ?? "").localizedCaseInsensitiveContains(query))
        }
    }
}
