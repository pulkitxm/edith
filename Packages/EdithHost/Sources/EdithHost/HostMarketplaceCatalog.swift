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
            id: "agents", title: "Agents",
            subtitle: "Usage, live sessions, review and memory for your coding agents.",
            symbol: "sparkles"),
        .init(
            id: "maintenance", title: "Maintenance",
            subtitle: "Updates, packages, review-first removal, disk cleanup and history.",
            symbol: "shippingbox.and.arrow.backward"),
        .init(
            id: "system", title: "System",
            subtitle: "Running apps, sleep, the cleaning lock, menu bar stats and mic mute.",
            symbol: "switch.2"),
        .init(
            id: "desk", title: "Desk",
            subtitle: "The launcher, clipboard and pickers, keystrokes, dimming and presenting.",
            symbol: "hand.tap"),
        .init(
            id: "media", title: "Media",
            subtitle: "Studio, music, downloads, the notch shelf and your calendar.",
            symbol: "play.rectangle.on.rectangle"),
        .init(
            id: "data", title: "Data",
            subtitle: "Databases, attention history and local site audits.",
            symbol: "cylinder.split.1x2"),
        .init(
            id: "tools", title: "Tools", subtitle: "Your fleet, documents and terminal.",
            symbol: "wrench.and.screwdriver"),
    ]
    static let subtitles: [String: String] = [
        "usage": "Claude, Codex and Cursor limits, usage stats, and alerts.",
        "herdr": "Live Herdr sessions on this Mac and your SSH machines.",
        "quinjet": "Review pull requests and live workspace changes in a native terminal.",
        "companion": "Your notes, voice memos and activity, remembered and searchable.",
        "plugins": "Install Edith skills for your coding agents.",
        "appMaintenance": "Verified app installs, updates, review-first removal and history.",
        "homebrew": "One Homebrew client for formulae, casks and taps.",
        "cleaner": "Find reclaimable space across your drives and remove it on review.",
        "blitztree": "Explore disk space with a treemap, largest files and cleanup candidates.",
        "system": "Running apps and the keyboard-cleaning lock.",
        "keepAwake": "Keep the Mac and display awake until you turn it off.",
        "lidAwake": "Keeps this Mac running with the lid shut, on battery and unplugged.",
        "systemStats": "Live CPU and memory readout as a menu bar item.",
        "micMute": "Mute every microphone system-wide with ⌘⇧M or the menu bar icon.",
        "bifrost": "One bar that opens any app and answers sums and unit questions.",
        "clipboard": "Clipboard history with instant paste.",
        "emoji": "Every macOS emoji on a hotkey, straight into the app you are typing in.",
        "colorPicker": "System loupe on a hotkey, sampled color to your clipboard.",
        "keystrokeHighlight": "Show each key press on screen for polished demos.",
        "focusDim": "Dims everything behind your active app.",
        "windowSweaters": "Knitted borders around your windows, in each app's own colours.",
        "presenter": "Blurs sensitive numbers while sharing your screen.",
        "studio": "Edit, convert, compress and combine images, PDFs, video and audio.",
        "latex": "Compile local documents or edit GitHub sources with pull request review.",
        "timeLapse": "Record displays or windows with audio, or capture a compact time-lapse.",
        "music": "Play local music, connect Spotify, or listen with YouTube Music.",
        "downloads": "Save videos, images and social posts with a persistent download queue.",
        "notchShelf": "File shelf, browser, now playing, camera, and alerts around the notch.",
        "audioMixer": "Per-app volume from the notch shelf.",
        "calendar": "Shows your schedule in the panel and the app.",
        "virtualCamera": "Frame, zoom and style your camera, then pick Edith Camera in any call.",
        "database": "Explore databases and run guarded production mutations.",
        "attention": "Understand where your time goes and protect focused work!",
        "seoAudit": "Crawl sitemaps, inspect page metadata, and keep every run local.",
        "codeStats": "Mirror your GitHub repositories and see how your own code grows.",
        "machines": "Your Mac and SSH machines, projects and services in one fleet.",
        "docs": "Browse and edit local documents and project notes.",
        "terminal": "A native terminal for local projects and SSH machines.",
        "jev": "A personal agent for decisions, tasks and connected services.",
    ]
    static func filter(_ entries: [HostExtension], query: String, category: String)
        -> [HostExtension]
    {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            (!query.isEmpty || category == "all" || entry.category == category)
                && (query.isEmpty || entry.title.localizedCaseInsensitiveContains(query)
                    || (subtitles[entry.id] ?? "").localizedCaseInsensitiveContains(query))
        }
    }
}
