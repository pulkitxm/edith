import Foundation

public enum HostAppLinksCLI {
    public static func entries(extensions: [HostExtension], contributors: [String: URL]) -> [(
        id: String, label: String, url: URL
    )] {
        var result: [(id: String, label: String, url: URL)] = [
            ("repository", "pulkitxm/edith", URL(string: "https://github.com/pulkitxm/edith")!),
            ("creator", "Pulkit", URL(string: "https://pulkit.page")!),
        ]
        for entry in extensions {
            for document in documents where document.owner == entry.id {
                result.append(
                    (
                        "extension-doc:" + entry.id + ":" + document.id,
                        entry.title + ": " + document.title,
                        URL(string: "https://github.com/pulkitxm/edith/blob/main/" + document.path)!
                    ))
            }
        }
        result += contributors.sorted { $0.key < $1.key }.map {
            ("contributor:" + $0.key, $0.key, $0.value)
        }
        return result
    }

    private struct Document {
        let owner: String
        let id: String
        let title: String
        let path: String
    }

    private static let documents: [Document] = [
        .init(owner: "latex", id: "guide", title: "LaTeX guide", path: "docs/latex.md"),
        .init(owner: "blitztree", id: "guide", title: "BlitzTree guide", path: "docs/blitztree.md"),
        .init(
            owner: "attention", id: "guide", title: "Attention guide",
            path: "docs/cli/attention/README.md"),
        .init(
            owner: "usage", id: "guide", title: "Agent Usage guide",
            path: "docs/cli/usage/README.md"),
        .init(owner: "herdr", id: "guide", title: "Herdr guide", path: "docs/cli/herdr/README.md"),
        .init(owner: "plugins", id: "guide", title: "Plugins guide", path: "docs/plugins.md"),
        .init(owner: "quinjet", id: "guide", title: "Quinjet guide", path: "docs/quinjet.md"),
        .init(
            owner: "seoAudit", id: "extensions", title: "Extensions guide",
            path: "docs/cli/extensions/README.md"),
        .init(
            owner: "codeStats", id: "cli", title: "Code Stats commands",
            path: "docs/cli/code-stats/README.md"),
        .init(owner: "system", id: "guide", title: "System guide", path: "docs/cli/apps/README.md"),
        .init(
            owner: "appMaintenance", id: "guide", title: "App Maintenance guide",
            path: "docs/app-maintenance.md"),
        .init(
            owner: "appMaintenance", id: "packages", title: "Homebrew package guide",
            path: "docs/homebrew-manager.md"),
        .init(
            owner: "machines", id: "guide", title: "Machines guide",
            path: "docs/cli/machines/README.md"),
        .init(
            owner: "database", id: "extensions", title: "Extensions guide",
            path: "docs/cli/extensions/README.md"),
        .init(owner: "companion", id: "guide", title: "Companion guide", path: "docs/companion.md"),
        .init(
            owner: "keepAwake", id: "guide", title: "Keep Awake settings",
            path: "docs/cli/config/README.md"),
        .init(
            owner: "systemStats", id: "guide", title: "System metrics guide",
            path: "docs/cli/system/README.md"),
        .init(
            owner: "micMute", id: "extensions", title: "Extensions guide",
            path: "docs/cli/extensions/README.md"),
        .init(
            owner: "lidAwake", id: "guide", title: "Lid Awake guide",
            path: "docs/cli/lid-awake/README.md"),
        .init(
            owner: "studio", id: "guide", title: "Studio guide", path: "docs/cli/studio/README.md"),
        .init(
            owner: "timeLapse", id: "guide", title: "Screen recording guide",
            path: "docs/time-lapse.md"),
        .init(owner: "music", id: "guide", title: "Music guide", path: "docs/cli/music/README.md"),
        .init(
            owner: "calendar", id: "guide", title: "Calendar guide",
            path: "docs/cli/calendar/README.md"),
        .init(
            owner: "virtualCamera", id: "guide", title: "Virtual Camera guide",
            path: "docs/cli/camera/README.md"),
        .init(
            owner: "notchShelf", id: "guide", title: "Shelf guide", path: "docs/cli/shelf/README.md"
        ),
        .init(
            owner: "clipboard", id: "guide", title: "Clipboard guide",
            path: "docs/cli/clipboard/README.md"),
        .init(
            owner: "keystrokeHighlight", id: "guide", title: "Keystroke Highlight guide",
            path: "docs/cli/keystroke-highlight/README.md"),
        .init(
            owner: "focusDim", id: "extensions", title: "Extensions guide",
            path: "docs/cli/extensions/README.md"),
        .init(
            owner: "windowSweaters", id: "guide", title: "Window Sweaters guide",
            path: "docs/window-sweaters.md"),
        .init(
            owner: "windowSweaters", id: "extensions", title: "Extensions guide",
            path: "docs/cli/extensions/README.md"),
        .init(
            owner: "presenter", id: "extensions", title: "Extensions guide",
            path: "docs/cli/extensions/README.md"),
        .init(
            owner: "bifrost", id: "guide", title: "Bifrost guide",
            path: "docs/cli/bifrost/README.md"),
        .init(
            owner: "emoji", id: "guide", title: "Emoji Picker guide",
            path: "docs/cli/emoji/README.md"),
        .init(
            owner: "colorPicker", id: "guide", title: "Color Picker guide",
            path: "docs/cli/color/README.md"),
        .init(
            owner: "homebrew", id: "guide", title: "Homebrew guide", path: "docs/cli/brew/README.md"
        ),
        .init(
            owner: "cleaner", id: "guide", title: "Cleaner guide",
            path: "docs/cli/cleaner/README.md"),
        .init(
            owner: "downloads", id: "guide", title: "Download guide",
            path: "docs/cli/download/README.md"),
        .init(
            owner: "audioMixer", id: "guide", title: "Notch Shelf guide",
            path: "docs/cli/shelf/README.md"),
    ]
}
