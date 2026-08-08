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
        "check-updates", "collect", "forget",
    ]

    static let notReachableFromTheUI: [String: String] = [
        "ed install": "the app links the CLI itself on launch; there is no button for it",
        "ed uninstall": "the app links the CLI on launch; unlinking has no button either",
        "ed completions install": "shell completion has no UI at all",
        "ed config import": "the app restores from iCloud rather than from a JSON file",
        "ed machines docker compose up":
            "the Docker window groups by project but never runs compose",
        "ed machines docker compose down":
            "the Docker window groups containers by compose project but never runs compose",
        "ed machines docker compose restart":
            "the Docker window restarts containers one at a time, never a whole project",
        "ed machines docker compose pull":
            "the Docker window never pulls images, for a project or otherwise",
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
        UICapability(
            "Cleaner drive picker", "sweep a folder for project junk",
            ["cleaner", "scan", "--root", "~/code"]),
        UICapability(
            "Cleaner card", "clean one category",
            ["cleaner", "clean", "--category", "npm", "--yes"]),

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
        UICapability(
            "Machine tools", "switch a port forward on",
            ["machines", "forwards", "on", "box", "1"]),
        UICapability(
            "Machine tools", "switch a port forward off",
            ["machines", "forwards", "off", "box", "1"]),
        UICapability(
            "Machine terminal", "type into an interactive shell",
            ["machines", "exec", "--tty", "box", "top"]),
        UICapability(
            "Docker window", "open a shell in a container",
            ["machines", "exec", "--tty", "box", "docker exec -it api sh"]),
        UICapability(
            "Docker window", "pause a container",
            ["machines", "docker", "pause", "box", "api"]),
        UICapability(
            "Docker window", "unpause a container",
            ["machines", "docker", "unpause", "box", "api"]),
        UICapability(
            "Machine finder", "search the folder",
            ["machines", "files", "search", "box", "/a", "x"]),
        UICapability(
            "Machine finder", "get info on a directory",
            ["machines", "files", "info", "box", "/a"]),
        UICapability(
            "Machine finder", "duplicate a file",
            ["machines", "files", "duplicate", "box", "/a"]),
        UICapability(
            "Machine finder", "undo the last move or rename",
            ["machines", "files", "undo", "box"]),
        UICapability("Workspace view", "list saved layouts", ["machines", "workspace", "ls"]),
        UICapability(
            "Workspace pane menu", "split a pane",
            ["machines", "workspace", "split", "1", "box"]),
        UICapability(
            "Workspace pane menu", "close a pane", ["machines", "workspace", "close", "1"]),
        UICapability(
            "Workspace tab strip", "point a pane at another machine",
            ["machines", "workspace", "point", "1", "box"]),
        UICapability(
            "Workspace toolbar", "even out the panes", ["machines", "workspace", "equalize"]),
        UICapability(
            "Download sheet", "cancel running downloads", ["download", "cancel"]),
        UICapability("Music page", "rescan the library", ["music", "rescan"]),
        UICapability(
            "Permissions pane", "relaunch after granting", ["app", "relaunch"]),
        UICapability(
            "Update schedule sheet", "clear the check history", ["app", "clear-updates"]),
        UICapability(
            "Workspace toolbar", "apply a layout preset",
            ["machines", "workspace", "new", "box", "--screen", "terminal"]),
        UICapability(
            "Workspace picker", "switch to another layout", ["machines", "workspace", "use", "a"]),
        UICapability(
            "Workspace picker", "rename a layout", ["machines", "workspace", "rename", "a", "b"]),
        UICapability(
            "Workspace picker", "delete a layout", ["machines", "workspace", "rm", "a"]),
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
        UICapability("Music page", "click a track to play it", ["music", "start", "song"]),
        UICapability(
            "Music page", "play a whole folder", ["music", "start", "--folder", "Chill"]),
        UICapability("Music footer", "drag the seek bar", ["music", "seek", "0.5"]),
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
        UICapability("Music footer", "toggle shuffle", ["music", "shuffle", "on"]),
        UICapability("Music footer", "toggle repeat", ["music", "repeat", "on"]),

        UICapability(
            "Machine finder", "download a remote file",
            ["machines", "files", "get", "box", "/etc/hosts"]),
        UICapability(
            "Machine finder", "upload a local file",
            ["machines", "files", "put", "box", "./x", "/tmp/x"]),

        UICapability(
            "Machine finder", "copy files", ["machines", "files", "cp", "box", "/a", "/b"]),
        UICapability(
            "Machine finder", "cut and paste files",
            ["machines", "files", "mv", "box", "/a", "/b"]),
        UICapability(
            "Machine finder", "rename a file",
            ["machines", "files", "rename", "box", "/a", "b"]),
        UICapability(
            "Machine finder", "make a folder", ["machines", "files", "mkdir", "box", "/a"]),
        UICapability(
            "Machine finder", "move files to the trash",
            ["machines", "files", "rm", "box", "/a"]),
        UICapability(
            "Add machine sheet", "store a login password",
            ["machines", "add", "box", "--host", "h", "--password-stdin"]),
        UICapability(
            "Add machine sheet", "store a key passphrase",
            ["machines", "edit", "box", "--key-passphrase-stdin"]),

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

        UICapability(
            "Extension sheet", "install a required CLI tool", ["tools", "install", "yt-dlp"]),
        UICapability(
            "Terminal broadcast bar", "send one line to every pane",
            ["machines", "broadcast", "--", "uptime"]),
        UICapability(
            "Rate limit cards", "refresh the limits now", ["usage", "limits", "--refresh"]),

        UICapability("System page", "quit one app", ["apps", "quit", "Safari"]),
        UICapability("System page", "quit all apps", ["apps", "quit", "--all", "--yes"]),

        UICapability("Menu bar", "open the panel", ["app", "open"]),
        UICapability("Menu bar", "quit Edith", ["app", "quit"]),
        UICapability("Menu bar", "lock the keyboard to clean it", ["app", "clean-keys"]),
        UICapability("Settings", "send a test notification", ["app", "test-notification"]),
        UICapability("About pane", "check for updates", ["app", "check-updates"]),
        UICapability("Dashboard", "re-collect agent usage", ["usage", "refresh"]),
        UICapability(
            "Dashboard machines menu", "count a machine's agent usage too",
            ["usage", "machines", "enable", "box"]),
        UICapability(
            "Dashboard machines menu", "stop counting a machine",
            ["usage", "machines", "disable", "box"]),
        UICapability(
            "Dashboard machines menu", "collect from the machines now",
            ["usage", "machines", "collect"]),
        UICapability(
            "Dashboard machines menu", "drop what a machine already gave",
            ["usage", "machines", "forget", "box"]),
        UICapability(
            "Dashboard machines chip", "show one machine's agents only",
            ["usage", "summary", "--machine", "box"]),
        UICapability(
            "Dashboard machines chip", "take a machine out of the charts",
            ["usage", "summary", "--machine", "local"]),
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
            guard UIParity.notReachableFromTheUI[walk.label] == nil else { continue }
            guard !claimed.contains(walk.label) else { continue }
            orphans.append(walk.label)
        }
        let complaint =
            "these change something but no UI action claims them, so the two surfaces have "
            + "drifted: \(orphans)"
        #expect(orphans.isEmpty, "\(complaint)")
    }

    @Test func nothingIsExemptedThatNoLongerExists() {
        for label in UIParity.notReachableFromTheUI.keys {
            #expect(Self.labels.contains(label), "\(label) is exempted but no longer exists")
        }
    }

    @Test func everyExemptionSaysWhyItIsOneAndIsStillNeeded() {
        for (label, reason) in UIParity.notReachableFromTheUI {
            #expect(
                reason.count > 15,
                "\(label) is exempted without saying why it has no UI counterpart")
        }
        let flagged = Set(
            Self.leaves
                .filter { UIParity.mutatingVerbs.contains($0.path.last ?? "") }
                .map(\.label))
        for label in UIParity.notReachableFromTheUI.keys {
            #expect(
                flagged.contains(label),
                "\(label) is exempted but nothing would have flagged it, so the row is dead")
        }
    }

    @Test func everyUIActionRowNamesARealSurfaceAndAction() {
        for capability in UIParity.capabilities {
            #expect(!capability.surface.isEmpty, "a capability row has no surface")
            #expect(
                capability.action.count > 3,
                "\(capability.label) does not say what the user does")
            #expect(!capability.cli.isEmpty, "\(capability.surface) claims no command")
        }
    }
}
