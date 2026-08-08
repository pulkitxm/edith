import ArgumentParser
import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

struct UICapability {
    let surface: String
    let action: String
    let cli: [String]

    init(_ surface: String, _ action: String, _ cli: [String]) {
        self.surface = surface
        self.action = action
        self.cli = cli
    }

    var label: String { (["ed"] + cli).joined(separator: " ") }
}

enum UIParity {
    static let mutatingVerbs: Set<String> = [
        "add", "rm", "rmi", "volume-rm", "remove", "set", "unset", "clear", "clean",
        "enable", "disable", "pin", "unpin", "copy", "edit", "import", "install",
        "uninstall", "refresh", "request", "play", "pause", "stop", "toggle", "next",
        "previous", "volume", "connect", "disconnect", "start", "restart", "prune",
        "up", "down", "pull", "put", "quit", "open", "clean-keys", "test-notification",
        "check-updates",
    ]

    static let notReachableFromTheUI: Set<String> = [
        "ed install", "ed uninstall", "ed completions install", "ed config import",
        "ed machines docker compose up", "ed machines docker compose down",
        "ed machines docker compose restart", "ed machines docker compose pull",
    ]

    static let capabilities: [UICapability] = [
        UICapability(
            "Settings", "change any preference the panes write", ["config", "set", "theme", "dim"]),
        UICapability(
            "Settings", "put a preference back to its default", ["config", "unset", "theme"]),
        UICapability(
            "Extensions pane", "turn an extension on", ["extensions", "enable", "clipboard"]),
        UICapability(
            "Extensions pane", "turn an extension off", ["extensions", "disable", "clipboard"]),
        UICapability(
            "Permissions pane", "raise a macOS permission prompt",
            ["permissions", "request", "calendar"]),
        UICapability(
            "Permissions pane", "re-read the real permission state", ["permissions", "refresh"]),

        UICapability("Clipboard panel", "click an entry to copy it", ["clipboard", "copy", "1"]),
        UICapability("Clipboard panel", "pin an entry", ["clipboard", "pin", "1"]),
        UICapability("Clipboard panel", "unpin an entry", ["clipboard", "unpin", "1"]),
        UICapability("Clipboard panel", "delete an entry", ["clipboard", "rm", "1"]),
        UICapability("Clipboard panel", "clear the history", ["clipboard", "clear"]),
        UICapability(
            "Clipboard panel", "search the history", ["clipboard", "ls", "--search", "x"]),
        UICapability(
            "Clipboard settings", "see how many entries and how big", ["clipboard", "stats"]),

        UICapability("Colour picker", "forget the picked colours", ["color", "clear"]),

        UICapability("Notch shelf", "drop a file onto the shelf", ["shelf", "add", "./file"]),
        UICapability("Notch shelf", "take an item off the shelf", ["shelf", "rm", "1"]),
        UICapability("Notch shelf", "empty the shelf", ["shelf", "clear"]),

        UICapability("Cleaner card", "reclaim the scanned caches", ["cleaner", "clean"]),

        UICapability("Machines", "add a machine", ["machines", "add", "box", "--host", "h"]),
        UICapability("Machines", "edit a machine", ["machines", "edit", "box"]),
        UICapability("Machines", "delete a machine", ["machines", "rm", "box"]),
        UICapability(
            "Machine tools", "save a port forward",
            ["machines", "forwards", "add", "box", "--local", "8080", "--remote", "80"]),
        UICapability(
            "Machine tools", "delete a port forward",
            ["machines", "forwards", "rm", "box", "1"]),
        UICapability(
            "Machine tools", "save a snippet",
            ["machines", "snippets", "add", "box", "logs", "journalctl"]),
        UICapability(
            "Machine tools", "delete a snippet", ["machines", "snippets", "rm", "box", "1"]),
        UICapability(
            "Machine tools", "restart the machine",
            ["machines", "power", "reboot", "box", "--yes"]),
        UICapability(
            "Machine tools", "shut the machine down",
            ["machines", "power", "shutdown", "box", "--yes"]),
        UICapability("Machine tools", "wake the machine", ["machines", "power", "wake", "box"]),
        UICapability(
            "Machine tools", "start a systemd unit",
            ["machines", "services", "start", "box", "nginx.service"]),
        UICapability(
            "Machine tools", "stop a systemd unit",
            ["machines", "services", "stop", "box", "nginx.service"]),
        UICapability(
            "Machine tools", "restart a systemd unit",
            ["machines", "services", "restart", "box", "nginx.service"]),
        UICapability(
            "Machine processes", "end a process with SIGTERM", ["machines", "kill", "box", "42"]),
        UICapability(
            "Machine processes", "force kill a process",
            ["machines", "kill", "box", "42", "--signal", "KILL"]),
        UICapability("Machines", "open the shared connection", ["machines", "connect", "box"]),
        UICapability("Machines", "close the shared connection", ["machines", "disconnect", "box"]),

        UICapability("Music player", "play", ["music", "play"]),
        UICapability("Music player", "pause", ["music", "pause"]),
        UICapability("Music player", "stop", ["music", "stop"]),
        UICapability("Music player", "play or pause with one key", ["music", "toggle"]),
        UICapability("Music player", "skip forward", ["music", "next"]),
        UICapability("Music player", "skip back", ["music", "previous"]),
        UICapability("Music player", "change the volume", ["music", "volume", "0.5"]),
        UICapability("Music page", "browse the library", ["music", "ls"]),
        UICapability(
            "Music page", "choose the music folder",
            ["config", "set", "musicFolderPath", "~/Music"]),
        UICapability("Music page", "make a folder", ["music", "mkdir", "Chill"]),
        UICapability("Music page", "move a track into a folder", ["music", "mv", "song", "Chill"]),
        UICapability("Music page", "rename a track", ["music", "rename", "song", "New"]),
        UICapability(
            "Music page", "rename a folder", ["music", "rename", "--folder", "Chill", "Calm"]),
        UICapability("Music page", "move a track to the Trash", ["music", "rm", "song", "--yes"]),
        UICapability(
            "Music page", "move a folder to the Trash",
            ["music", "rm", "--folder", "Chill", "--yes"]),
        UICapability(
            "Music footer", "toggle shuffle", ["config", "set", "musicShuffling", "true"]),
        UICapability("Music footer", "toggle repeat", ["config", "set", "musicLooping", "true"]),

        UICapability(
            "Machine finder", "download a remote file",
            ["machines", "files", "get", "box", "/etc/hosts"]),
        UICapability(
            "Machine finder", "upload a local file",
            ["machines", "files", "put", "box", "./x", "/tmp/x"]),

        UICapability(
            "Docker window", "start a container", ["machines", "docker", "start", "box", "api"]),
        UICapability(
            "Docker window", "stop a container", ["machines", "docker", "stop", "box", "api"]),
        UICapability(
            "Docker window", "restart a container",
            ["machines", "docker", "restart", "box", "api"]),
        UICapability(
            "Docker window", "remove a container", ["machines", "docker", "rm", "box", "api"]),
        UICapability(
            "Docker window", "remove an image", ["machines", "docker", "rmi", "box", "nginx"]),
        UICapability(
            "Docker window", "remove a volume",
            ["machines", "docker", "volume-rm", "box", "data"]),
        UICapability(
            "Docker window", "prune unused objects",
            ["machines", "docker", "prune", "box", "images"]),

        UICapability("Download sheet", "start a download", ["download", "add", "https://x/y"]),
        UICapability("Download sheet", "retry a failed item", ["download", "retry", "--all"]),
        UICapability("Download sheet", "clear the history", ["download", "clear"]),
        UICapability("Download sheet", "remove one item", ["download", "rm", "1"]),
        UICapability("Download sheet", "update yt-dlp", ["download", "tool", "--update"]),

        UICapability("System page", "quit one app", ["apps", "quit", "Safari"]),
        UICapability("System page", "quit all apps", ["apps", "quit", "--all", "--yes"]),

        UICapability("Menu bar", "open the panel", ["app", "open"]),
        UICapability("Menu bar", "quit Edith", ["app", "quit"]),
        UICapability("Menu bar", "lock the keyboard to clean it", ["app", "clean-keys"]),
        UICapability("Settings", "send a test notification", ["app", "test-notification"]),
        UICapability("About pane", "check for updates", ["app", "check-updates"]),
        UICapability("Dashboard", "re-collect agent usage", ["usage", "refresh"]),
    ]
}

@Suite struct CLIParityTests {
    static let leaves = CommandCrawler.every().filter {
        $0.type.configuration.subcommands.isEmpty
    }
    static let labels = Set(CommandCrawler.every().map(\.label))

    static func commandPath(_ cli: [String]) -> String {
        var current = "ed"
        for word in cli where !word.hasPrefix("-") {
            let candidate = current + " " + word
            guard labels.contains(candidate) else { break }
            current = candidate
        }
        return current
    }

    @Test func everyUIActionNamesACommandTheCLIActuallyHas() {
        for capability in UIParity.capabilities {
            let resolved = Self.commandPath(capability.cli)
            let complaint =
                "\(capability.surface) can \(capability.action) but `\(capability.label)` "
                + "is not a command"
            #expect(resolved != "ed", "\(complaint)")
        }
    }

    @Test func everyUIActionParsesWithTheArgumentsItClaims() throws {
        for capability in UIParity.capabilities {
            #expect(
                throws: Never.self,
                "`\(capability.label)` does not parse, so the UI action has no working verb"
            ) {
                _ = try EdRoot.parseAsRoot(capability.cli)
            }
        }
    }

    @Test func everyMappedCommandIsAlsoInTheCompletionTree() {
        for capability in UIParity.capabilities {
            var node = CommandTree.root
            var walked: [String] = []
            for word in capability.cli where !word.hasPrefix("-") {
                guard let child = node.child(word) else { break }
                node = child
                walked.append(word)
            }
            #expect(
                !walked.isEmpty,
                "`\(capability.label)` is missing from CommandTree, so it will not complete")
        }
    }

    @Test func everyMutatingCommandIsClaimedByAUIAction() {
        let claimed = Set(UIParity.capabilities.map { Self.commandPath($0.cli) })
        var orphans: [String] = []
        for walk in Self.leaves {
            let verb = walk.path.last ?? ""
            guard UIParity.mutatingVerbs.contains(verb) else { continue }
            guard !UIParity.notReachableFromTheUI.contains(walk.label) else { continue }
            guard !claimed.contains(walk.label) else { continue }
            orphans.append(walk.label)
        }
        let complaint =
            "these change something but no UI action claims them, so the two surfaces have "
            + "drifted: \(orphans)"
        #expect(orphans.isEmpty, "\(complaint)")
    }

    @Test func nothingIsExemptedThatNoLongerExists() {
        for label in UIParity.notReachableFromTheUI {
            #expect(Self.labels.contains(label), "\(label) is exempted but no longer exists")
        }
    }
}
