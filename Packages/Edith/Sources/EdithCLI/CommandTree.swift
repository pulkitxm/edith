import Foundation

public enum ArgumentKind: Equatable, Sendable {
    case machine
    case appAction
    case cleanerCategory
    case colorFormat
    case pruneTarget
    case composeProject
    case historyIndex
    case configKey
    case configValue
    case extensionID
    case permission
    case shell
    case group
    case usageRange
    case localPath
    case remotePath
    case container
    case free
}

public struct CommandNode: Equatable, Sendable {
    public let name: String
    public let summary: String
    public let aliases: [String]
    public let options: [String]
    public let arguments: [ArgumentKind]
    public let children: [CommandNode]

    public init(
        _ name: String, _ summary: String, aliases: [String] = [], options: [String] = [],
        arguments: [ArgumentKind] = [], children: [CommandNode] = []
    ) {
        self.name = name
        self.summary = summary
        self.aliases = aliases
        self.options = options
        self.arguments = arguments
        self.children = children
    }

    public var names: [String] { [name] + aliases }

    public func child(_ name: String) -> CommandNode? {
        children.first { $0.names.contains(name) }
    }
}

public enum CommandTree {
    public static let common = ["--json", "--help"]
    public static let playback = ["--json", "--help", "--player"]

    public static let root = CommandNode(
        "ed", "The command line for Edith.", options: ["--help", "--version"],
        children: [
            CommandNode("guide", "Print the built-in manual.", arguments: [.free]),
            CommandNode("schema", "Print the JSON Schema for the config document.", options: []),
            CommandNode("version", "Print the Edith CLI version.", options: common),
            CommandNode(
                "completions", "Generate or install shell completions.",
                children: [
                    CommandNode(
                        "install", "Install completions for the detected shells.",
                        options: ["--json", "--shell"], arguments: [.shell]),
                    CommandNode("zsh", "Print the zsh completion script."),
                    CommandNode("bash", "Print the bash completion script."),
                    CommandNode("fish", "Print the fish completion script."),
                ]),
            CommandNode(
                "install", "Link ed, edh and edith into a directory on PATH.",
                options: ["--json", "--directory"]),
            CommandNode(
                "uninstall", "Remove the ed, edh and edith links.", options: ["--json"]),
            CommandNode(
                "config", "Read and write every setting the UI exposes.",
                children: [
                    CommandNode(
                        "ls", "List settings and their current values.", aliases: ["list"],
                        options: ["--json", "--group", "--changed"], arguments: [.group]),
                    CommandNode(
                        "get", "Print one setting.", options: common, arguments: [.configKey]),
                    CommandNode(
                        "set", "Write one setting.", options: ["--json"],
                        arguments: [.configKey, .configValue]),
                    CommandNode(
                        "unset", "Restore one setting to its default.", options: ["--json"],
                        arguments: [.configKey]),
                    CommandNode(
                        "describe", "Explain one setting.", options: common,
                        arguments: [.configKey]),
                    CommandNode(
                        "export", "Print changed settings as one JSON document.",
                        options: ["--defaults"]),
                    CommandNode(
                        "import", "Apply a JSON document of settings.",
                        options: ["--json", "--dry-run"], arguments: [.localPath]),
                ]),
            CommandNode(
                "app", "One-shot actions the Edith app performs.",
                children: [
                    CommandNode(
                        "actions", "List the one-shot actions.", aliases: ["ls"],
                        options: common),
                    CommandNode("clean-keys", "Lock the keyboard for wiping.", options: common),
                    CommandNode(
                        "test-notification", "Send a test notification.", options: common),
                    CommandNode("open", "Open Edith's panel.", options: common),
                    CommandNode("quit", "Quit the Edith main window.", options: common),
                    CommandNode(
                        "check-updates", "Check for an update now.",
                        options: ["--json", "--help", "--no-wait"]),
                    CommandNode(
                        "updates", "The update checks already made.",
                        options: ["--json", "--help", "--limit"]),
                    CommandNode("relaunch", "Quit Edith and start it again.", options: common),
                    CommandNode(
                        "clear-updates", "Forget the record of past update checks.",
                        options: common),
                ]),
            CommandNode(
                "extensions", "Turn Edith's extensions on and off.",
                children: [
                    CommandNode(
                        "ls", "List extensions.", aliases: ["list"], options: common),
                    CommandNode(
                        "enable", "Turn an extension on.", options: ["--json"],
                        arguments: [.extensionID]),
                    CommandNode(
                        "disable", "Turn an extension off.", options: ["--json"],
                        arguments: [.extensionID]),
                    CommandNode(
                        "info", "Describe one extension.", options: common,
                        arguments: [.extensionID]),
                ]),
            CommandNode(
                "permissions", "Inspect and request Edith's macOS permissions.",
                children: [
                    CommandNode(
                        "ls", "List permissions.", aliases: ["list"],
                        options: ["--json", "--help", "--attention"]),
                    CommandNode(
                        "request", "Ask the app to request a permission.", options: ["--json"],
                        arguments: [.permission]),
                    CommandNode(
                        "refresh", "Ask the app to re-read the real TCC state.",
                        options: ["--json"]),
                ]),
            CommandNode(
                "usage", "Agent usage, token counts, cost and rate limits.",
                children: [
                    CommandNode(
                        "limits", "Session and weekly limits per provider.",
                        options: ["--json", "--help", "--refresh"]),
                    CommandNode(
                        "summary", "Cost and tokens over a window.",
                        options: ["--json", "--range", "--source", "--machine"],
                        arguments: [.usageRange]),
                    CommandNode(
                        "daily", "Per-day cost and tokens.",
                        options: ["--json", "--range", "--source", "--machine"]),
                    CommandNode(
                        "models", "Cost and tokens per model.",
                        options: ["--json", "--range", "--source", "--machine"]),
                    CommandNode(
                        "projects", "Cost and tokens per GitHub repository.",
                        options: ["--json", "--range", "--limit"]),
                    CommandNode(
                        "sources", "The agents that produced the history.",
                        options: common),
                    CommandNode(
                        "machines", "Machines counted with this Mac.",
                        children: [
                            CommandNode(
                                "ls", "Every machine and what its usage adds up to.",
                                options: common),
                            CommandNode(
                                "collect", "Run the collector on a machine and bring it back.",
                                options: ["--json", "--verbose", "--once", "--timeout"],
                                arguments: [.machine]),
                            CommandNode(
                                "enable", "Count this machine on every refresh.",
                                options: ["--json"], arguments: [.machine]),
                            CommandNode(
                                "disable", "Stop collecting from this machine.",
                                options: ["--json"], arguments: [.machine]),
                            CommandNode(
                                "forget", "Drop what a machine gave and stop counting it.",
                                options: ["--json"], arguments: [.machine]),
                        ]),
                    CommandNode(
                        "refresh", "Re-collect usage here and on the machines.",
                        options: ["--json", "--follow", "--machines", "--no-machines"]),
                ]),
            CommandNode(
                "system", "Metrics for this Mac.",
                children: [
                    CommandNode(
                        "stats", "Sample CPU, memory, load and network.",
                        options: ["--json", "--follow", "--interval", "--processes"]),
                    CommandNode("disks", "Mounted volumes and their free space.", options: common),
                ]),
            CommandNode(
                "music", "Whatever is playing, and playback control.",
                aliases: ["nowplaying", "np"], options: playback,
                children: [
                    CommandNode(
                        "status", "What is playing right now.", options: playback,
                        arguments: []),
                    CommandNode("players", "Every player, and which is active.", options: common),
                    CommandNode("play", "Resume playback.", options: playback),
                    CommandNode("pause", "Pause playback.", options: playback),
                    CommandNode("stop", "Stop playback and reset the position.", options: playback),
                    CommandNode(
                        "toggle", "Toggle play and pause.", aliases: ["playpause"],
                        options: playback),
                    CommandNode("next", "Skip to the next track.", options: playback),
                    CommandNode(
                        "previous", "Go back to the previous track.", aliases: ["prev"],
                        options: playback),
                    CommandNode(
                        "volume", "Set the player volume from 0 to 1.", options: playback),
                    CommandNode(
                        "start", "Play one track, or a whole folder.",
                        options: ["--json", "--help", "--folder"], arguments: [.free]),
                    CommandNode("rescan", "Read the music folder again.", options: common),
                    CommandNode(
                        "seek", "Jump to a point in the track.", options: common,
                        arguments: [.free]),
                    CommandNode(
                        "shuffle", "Turn shuffle on or off.", options: common,
                        arguments: [.free]),
                    CommandNode(
                        "repeat", "Turn repeat on or off.", aliases: ["loop"], options: common,
                        arguments: [.free]),
                    CommandNode(
                        "ls", "List the library a folder at a time.", aliases: ["list"],
                        options: ["--json", "--help", "--folders", "--recursive", "--search"],
                        arguments: [.free]),
                    CommandNode(
                        "mkdir", "Make a folder in the library.", aliases: ["newfolder"],
                        options: ["--json", "--help", "--under"], arguments: [.free]),
                    CommandNode(
                        "mv", "Move a track into a folder.", aliases: ["move"], options: common,
                        arguments: [.free]),
                    CommandNode(
                        "rename", "Rename a track or folder.",
                        options: ["--json", "--help", "--folder"], arguments: [.free]),
                    CommandNode(
                        "rm", "Move a track or folder to the Trash.",
                        options: ["--json", "--help", "--folder", "--yes"], arguments: [.free]),
                ]),
            CommandNode(
                "calendar", "Your schedule.",
                children: [
                    CommandNode(
                        "ls", "Upcoming events.", aliases: ["list"],
                        options: ["--json", "--days"])
                ]),
            CommandNode(
                "tools", "Command line tools the extensions rely on.",
                children: [
                    CommandNode(
                        "ls", "List the tools and whether they are installed.",
                        aliases: ["list"], options: common),
                    CommandNode(
                        "install", "Install one of the tools.", options: common,
                        arguments: [.free]),
                ]),
            CommandNode(
                "apps", "The applications running on this Mac.",
                children: [
                    CommandNode(
                        "ls", "List apps with a window open.", aliases: ["list"],
                        options: common),
                    CommandNode(
                        "quit", "Quit one app, or everything else.",
                        options: ["--json", "--help", "--all", "--force", "--yes"],
                        arguments: [.free]),
                ]),
            CommandNode(
                "download", "The download queue Edith feeds to yt-dlp.",
                aliases: ["downloads", "dl"],
                children: [
                    CommandNode(
                        "ls", "List the queue.", aliases: ["list"],
                        options: ["--json", "--help", "--active", "--limit"]),
                    CommandNode(
                        "add", "Queue one or more URLs.",
                        options: ["--json", "--help", "--kind", "--prefix"], arguments: [.free]),
                    CommandNode(
                        "retry", "Queue a failed download again.",
                        options: ["--json", "--help", "--all"], arguments: [.historyIndex]),
                    CommandNode(
                        "rm", "Take one entry out of the queue.", options: common,
                        arguments: [.historyIndex]),
                    CommandNode(
                        "clear", "Forget what has finished.",
                        options: ["--json", "--help", "--everything"]),
                    CommandNode(
                        "cancel", "Stop downloading and empty the queue.", options: common),
                    CommandNode(
                        "tool", "Report or update yt-dlp.",
                        options: ["--json", "--help", "--update"]),
                ]),
            CommandNode(
                "clipboard", "The clipboard history Edith keeps.",
                children: [
                    CommandNode(
                        "ls", "List the clipboard history.", aliases: ["list"],
                        options: ["--json", "--help", "--pinned", "--search", "--limit"]),
                    CommandNode(
                        "stats", "How many entries there are and what they weigh.",
                        aliases: ["size"], options: common),
                    CommandNode(
                        "get", "Print one entry as text.", options: common,
                        arguments: [.historyIndex]),
                    CommandNode(
                        "copy", "Put one entry back on the pasteboard.",
                        options: ["--json", "--help", "--plain"], arguments: [.historyIndex]),
                    CommandNode(
                        "pin", "Keep one entry at the top.", options: common,
                        arguments: [.historyIndex]),
                    CommandNode(
                        "unpin", "Let one entry age out again.", options: common,
                        arguments: [.historyIndex]),
                    CommandNode(
                        "rm", "Forget one entry.", options: ["--json"],
                        arguments: [.historyIndex]),
                    CommandNode(
                        "clear", "Forget the whole history.",
                        options: ["--json", "--help", "--keep-pinned"]),
                ]),
            CommandNode(
                "color", "The colours picked with the colour picker.", aliases: ["colour"],
                children: [
                    CommandNode(
                        "ls", "List picked colours.", aliases: ["list"],
                        options: ["--json", "--help", "--format", "--limit"],
                        arguments: [.colorFormat]),
                    CommandNode("clear", "Forget every picked colour.", options: ["--json"]),
                ]),
            CommandNode(
                "shelf", "The files parked on the notch shelf.",
                children: [
                    CommandNode(
                        "ls", "List what is on the shelf.", aliases: ["list"], options: common),
                    CommandNode(
                        "path", "Print the path of one item.", options: common,
                        arguments: [.historyIndex]),
                    CommandNode(
                        "add", "Copy a file onto the shelf.", options: ["--json"],
                        arguments: [.localPath]),
                    CommandNode(
                        "rm", "Take one item off the shelf.", options: ["--json"],
                        arguments: [.historyIndex]),
                    CommandNode("clear", "Empty the shelf.", options: ["--json"]),
                ]),
            CommandNode(
                "cleaner", "The developer caches the disk cleaner can reclaim.",
                children: [
                    CommandNode(
                        "scan", "Measure what could be reclaimed.",
                        options: ["--json", "--help", "--category", "--root"],
                        arguments: [.cleanerCategory]),
                    CommandNode(
                        "categories", "The caches the cleaner knows.", aliases: ["ls"],
                        options: common),
                    CommandNode(
                        "clean", "Move the scanned caches to the Trash.",
                        options: ["--json", "--help", "--category", "--yes"]),
                    CommandNode("drives", "The volumes the cleaner can scan.", options: common),
                ]),
            CommandNode(
                "machines", "The computers Edith can reach over SSH.",
                arguments: [.machine],
                children: [
                    CommandNode(
                        "ls", "List configured machines.", aliases: ["list"], options: common),
                    CommandNode(
                        "show", "One machine, with live facts.", options: common,
                        arguments: [.machine]),
                    CommandNode(
                        "add", "Add a machine to Edith's list.",
                        options: [
                            "--json", "--help", "--host", "--port", "--user", "--key",
                            "--alias", "--mac",
                        ],
                        arguments: [.free]),
                    CommandNode(
                        "edit", "Change a machine already on the list.",
                        options: [
                            "--json", "--help", "--name", "--host", "--port", "--user",
                            "--key", "--agent", "--mac", "--sudo-password-stdin",
                            "--forget-sudo-password",
                        ],
                        arguments: [.machine]),
                    CommandNode(
                        "rm", "Forget a machine and everything saved against it.",
                        aliases: ["remove"], options: ["--json", "--help", "--yes"],
                        arguments: [.machine]),
                    CommandNode(
                        "forwards", "Saved port forwards.", aliases: ["forward"],
                        children: [
                            CommandNode(
                                "ls", "List a machine's port forwards.", aliases: ["list"],
                                options: common, arguments: [.machine]),
                            CommandNode(
                                "add", "Save a port forward.",
                                options: [
                                    "--json", "--help", "--local", "--remote",
                                    "--remote-host", "--title",
                                ],
                                arguments: [.machine]),
                            CommandNode(
                                "on", "Open a saved forward on the connection.",
                                options: common, arguments: [.machine, .historyIndex]),
                            CommandNode(
                                "off", "Close a saved forward.", options: common,
                                arguments: [.machine, .historyIndex]),
                            CommandNode(
                                "rm", "Forget one port forward.", aliases: ["remove"],
                                options: common, arguments: [.machine, .historyIndex]),
                        ]),
                    CommandNode(
                        "snippets", "Saved commands.", aliases: ["snippet"],
                        children: [
                            CommandNode(
                                "ls", "List a machine's snippets.", aliases: ["list"],
                                options: common, arguments: [.machine]),
                            CommandNode(
                                "add", "Save a command against a machine.",
                                options: ["--json", "--help", "--shared"],
                                arguments: [.machine, .free]),
                            CommandNode(
                                "rm", "Forget one snippet.", aliases: ["remove"],
                                options: common, arguments: [.machine, .historyIndex]),
                        ]),
                    CommandNode(
                        "power", "Restart, shut down or wake a machine.",
                        children: [
                            CommandNode(
                                "status", "Whether a machine is up and what it can be told.",
                                options: common, arguments: [.machine]),
                            CommandNode(
                                "reboot", "Restart a machine.", aliases: ["restart"],
                                options: ["--json", "--help", "--yes"], arguments: [.machine]),
                            CommandNode(
                                "shutdown", "Shut a machine down.", aliases: ["poweroff"],
                                options: ["--json", "--help", "--yes"], arguments: [.machine]),
                            CommandNode(
                                "wake", "Send a wake-on-LAN packet.", options: common,
                                arguments: [.machine]),
                        ]),
                    CommandNode(
                        "workspace", "Saved multi-pane layouts.", aliases: ["workspaces"],
                        children: [
                            CommandNode(
                                "ls", "List saved workspaces.", aliases: ["list"],
                                options: common),
                            CommandNode(
                                "use", "Make one the current workspace.", options: common,
                                arguments: [.free]),
                            CommandNode(
                                "new", "Build one with a pane per machine.",
                                options: ["--json", "--help", "--screen", "--name"],
                                arguments: [.machine]),
                            CommandNode(
                                "rename", "Rename a workspace.", options: common,
                                arguments: [.free]),
                            CommandNode(
                                "rm", "Forget a workspace.", aliases: ["remove"],
                                options: common, arguments: [.free]),
                            CommandNode(
                                "panes", "The panes and what they show.",
                                options: ["--json", "--help", "--workspace"]),
                            CommandNode(
                                "split", "Split a pane.",
                                options: ["--json", "--help", "--workspace", "--side", "--screen"],
                                arguments: [.historyIndex, .machine]),
                            CommandNode(
                                "close", "Close a pane.",
                                options: ["--json", "--help", "--workspace"],
                                arguments: [.historyIndex]),
                            CommandNode(
                                "point", "Point a pane somewhere else.",
                                options: ["--json", "--help", "--workspace", "--screen"],
                                arguments: [.historyIndex, .machine]),
                            CommandNode(
                                "equalize", "Even out every split.", aliases: ["even"],
                                options: ["--json", "--help", "--workspace"]),
                        ]),
                    CommandNode(
                        "broadcast", "Run one command on every machine.",
                        options: ["--json", "--help", "--only"], arguments: [.free]),
                    CommandNode(
                        "kill", "End a process on a machine.",
                        options: ["--json", "--help", "--signal"],
                        arguments: [.machine, .historyIndex]),
                    CommandNode(
                        "metrics", "Sample a machine.",
                        options: ["--json", "--follow", "--interval", "--processes"],
                        arguments: [.machine]),
                    CommandNode(
                        "exec", "Run a command on a machine.", aliases: ["run"],
                        arguments: [.machine, .free]),
                    CommandNode(
                        "files", "Browse and transfer files.",
                        children: [
                            CommandNode(
                                "ls", "List a remote directory.", aliases: ["list"],
                                options: ["--json", "--help", "--all"],
                                arguments: [.machine, .remotePath]),
                            CommandNode(
                                "get", "Download a file.", options: ["--json"],
                                arguments: [.machine, .remotePath, .localPath]),
                            CommandNode(
                                "put", "Upload a file.", options: ["--json"],
                                arguments: [.machine, .localPath, .remotePath]),
                            CommandNode(
                                "cp", "Copy files into a directory there.", options: common,
                                arguments: [.machine, .remotePath]),
                            CommandNode(
                                "mv", "Move files into a directory there.", options: common,
                                arguments: [.machine, .remotePath]),
                            CommandNode(
                                "rename", "Rename one file there.", options: common,
                                arguments: [.machine, .remotePath]),
                            CommandNode(
                                "mkdir", "Make a directory there.", options: common,
                                arguments: [.machine, .remotePath]),
                            CommandNode(
                                "search", "Find files by name under a directory.",
                                options: ["--json", "--help", "--limit"],
                                arguments: [.machine, .remotePath, .free]),
                            CommandNode(
                                "info", "How big something is, directories included.",
                                options: common, arguments: [.machine, .remotePath]),
                            CommandNode(
                                "undo", "Undo the last change a Finder window made.",
                                options: common, arguments: [.machine]),
                            CommandNode(
                                "open", "Open the Files window on a directory.",
                                options: common, arguments: [.machine, .remotePath]),
                            CommandNode(
                                "duplicate", "Copy a file beside itself.", options: common,
                                arguments: [.machine, .remotePath]),
                            CommandNode(
                                "rm", "Trash or delete files there.",
                                options: ["--json", "--help", "--delete", "--yes"],
                                arguments: [.machine, .remotePath]),
                        ]),
                    CommandNode(
                        "docker", "Containers on a machine.",
                        children: [
                            CommandNode(
                                "ps", "List containers.", options: ["--json", "--all"],
                                arguments: [.machine]),
                            CommandNode(
                                "images", "List images.", options: common,
                                arguments: [.machine]),
                            CommandNode(
                                "volumes", "List volumes.", options: common,
                                arguments: [.machine]),
                            CommandNode(
                                "networks", "List networks.", options: common,
                                arguments: [.machine]),
                            CommandNode(
                                "df", "Disk usage by object type.", options: common,
                                arguments: [.machine]),
                            CommandNode(
                                "logs", "Container logs.",
                                options: ["--tail", "--follow"],
                                arguments: [.machine, .container]),
                            CommandNode(
                                "inspect", "Raw inspect output.",
                                arguments: [.machine, .container]),
                            CommandNode(
                                "start", "Start a container.", options: ["--json"],
                                arguments: [.machine, .container]),
                            CommandNode(
                                "stop", "Stop a container.", options: ["--json"],
                                arguments: [.machine, .container]),
                            CommandNode(
                                "restart", "Restart a container.", options: ["--json"],
                                arguments: [.machine, .container]),
                            CommandNode(
                                "rm", "Remove a container.", options: ["--json"],
                                arguments: [.machine, .container]),
                            CommandNode(
                                "pause", "Freeze a container.", options: ["--json"],
                                arguments: [.machine, .container]),
                            CommandNode(
                                "unpause", "Let a frozen container run.", options: ["--json"],
                                arguments: [.machine, .container]),
                            CommandNode(
                                "rmi", "Remove an image.", aliases: ["remove-image"],
                                options: ["--json", "--help", "--force"],
                                arguments: [.machine, .free]),
                            CommandNode(
                                "volume-rm", "Remove a volume and the data in it.",
                                options: ["--json", "--help", "--yes"],
                                arguments: [.machine, .free]),
                            CommandNode(
                                "prune", "Reclaim space from unused objects.",
                                options: ["--json", "--help", "--yes"],
                                arguments: [.machine, .pruneTarget]),
                            CommandNode(
                                "compose", "Compose projects on a machine.",
                                children: [
                                    CommandNode(
                                        "ls", "List compose projects.", aliases: ["list"],
                                        options: common, arguments: [.machine]),
                                    CommandNode(
                                        "up", "Bring a project up.", options: ["--json"],
                                        arguments: [.machine, .composeProject]),
                                    CommandNode(
                                        "down", "Take a project down.", options: ["--json"],
                                        arguments: [.machine, .composeProject]),
                                    CommandNode(
                                        "restart", "Restart a project.", options: ["--json"],
                                        arguments: [.machine, .composeProject]),
                                    CommandNode(
                                        "pull", "Pull a project's images.",
                                        options: ["--json"],
                                        arguments: [.machine, .composeProject]),
                                    CommandNode(
                                        "logs", "Logs for a whole project.",
                                        options: ["--tail", "--follow", "--help"],
                                        arguments: [.machine, .composeProject]),
                                ]),
                        ]),
                    CommandNode(
                        "services", "systemd units on a machine.",
                        children: [
                            CommandNode(
                                "ls", "List systemd units.", aliases: ["list"],
                                options: ["--json", "--failed"], arguments: [.machine]),
                            CommandNode(
                                "start", "Start a unit.", options: common,
                                arguments: [.machine, .free]),
                            CommandNode(
                                "stop", "Stop a unit.", options: common,
                                arguments: [.machine, .free]),
                            CommandNode(
                                "restart", "Restart a unit.", options: common,
                                arguments: [.machine, .free]),
                        ]),
                    CommandNode(
                        "connect", "Open the shared SSH connection.", options: ["--json"],
                        arguments: [.machine]),
                    CommandNode(
                        "disconnect", "Close the shared SSH connection.", options: ["--json"],
                        arguments: [.machine]),
                    CommandNode(
                        "mount", "Mount a machine's file system on this Mac.",
                        options: ["--json", "--help", "--at", "--read-only"],
                        arguments: [.machine, .remotePath]),
                    CommandNode(
                        "unmount", "Unmount a machine's file system.", aliases: ["umount"],
                        options: ["--json"], arguments: [.machine]),
                    CommandNode(
                        "mounts", "Every machine file system mounted here.", options: common),
                ]),
            CommandNode(
                "companion", "The companion memory backend.",
                children: [
                    CommandNode(
                        "status", "Count what the companion remembers.",
                        options: common + ["--endpoint"]),
                    CommandNode(
                        "doctor", "Check the companion's dependencies.",
                        options: common + ["--endpoint"]),
                    CommandNode(
                        "search", "Search companion memory with hybrid retrieval.",
                        options: common + ["--endpoint", "--limit"], arguments: [.free]),
                    CommandNode(
                        "index", "Embed pending companion episodes.",
                        options: common + ["--endpoint"]),
                    CommandNode(
                        "ingest", "Ingest Markdown notes and voice recordings as episodes.",
                        options: ["--json", "--endpoint"], arguments: [.localPath]),
                    CommandNode(
                        "episodes", "List recent companion episodes.",
                        options: common + ["--endpoint", "--limit"]),
                    CommandNode(
                        "episode", "Read one episode in full.",
                        options: common + ["--endpoint", "--body", "--open"],
                        arguments: [.free]),
                    CommandNode(
                        "sync", "Pull a connector's activity into observations.",
                        options: common + ["--endpoint", "--full"], arguments: [.free]),
                    CommandNode(
                        "observations", "List what the connectors saw you do.",
                        options: common + ["--endpoint", "--limit", "--kind"]),
                    CommandNode(
                        "reflect", "Distill fresh beliefs from recent episodes.",
                        options: common + ["--endpoint"]),
                    CommandNode(
                        "beliefs", "List what the companion believes about you.",
                        options: common + ["--endpoint", "--limit"]),
                    CommandNode(
                        "ask", "Ask a question answered from your own memory.",
                        options: common + ["--endpoint", "--persona"], arguments: [.free]),
                    CommandNode(
                        "council", "Ask several lenses at once and find the crux.",
                        options: common + ["--endpoint", "--personas"], arguments: [.free]),
                    CommandNode(
                        "personas", "List the lenses that can answer, and how each thinks.",
                        options: common + ["--endpoint"]),
                    CommandNode(
                        "lenses", "What each lens learned about being useful to you.",
                        options: common + ["--endpoint"]),
                    CommandNode(
                        "core", "Read or edit the standing summary of who you are.",
                        children: [
                            CommandNode(
                                "show", "Print the standing summary section by section.",
                                options: common + ["--endpoint"]),
                            CommandNode(
                                "set", "Rewrite one section of the standing summary.",
                                options: common + ["--endpoint"], arguments: [.free, .free]),
                        ]),
                    CommandNode(
                        "why", "Print the whole chain behind a belief, theory or claim.",
                        options: common + ["--endpoint"], arguments: [.free]),
                    CommandNode(
                        "hypotheses", "The theories it holds about you.",
                        children: [
                            CommandNode(
                                "ls", "List the theories and how they are faring.",
                                options: common + ["--endpoint", "--limit"]),
                            CommandNode(
                                "run", "Resolve due predictions, then form new theories.",
                                options: common + ["--endpoint"]),
                        ]),
                    CommandNode(
                        "predictions", "What it expects to happen, and what did.",
                        options: common + ["--endpoint", "--limit"]),
                    CommandNode(
                        "commitments", "What you said you would do, and what happened.",
                        options: common + ["--endpoint", "--limit"]),
                    CommandNode(
                        "discrepancies", "Where your account and the record parted company.",
                        children: [
                            CommandNode(
                                "ls", "List where the two parted company.",
                                options: common + ["--endpoint", "--limit"]),
                            CommandNode(
                                "override", "Say the work was real and the record missed it.",
                                options: common + ["--endpoint", "--real"], arguments: [.free]),
                        ]),
                    CommandNode(
                        "calibration", "How your account compares with the record.",
                        options: common + ["--endpoint"]),
                    CommandNode(
                        "inquire", "The questions it wants to ask you.",
                        children: [
                            CommandNode(
                                "next", "The one question worth asking right now.",
                                options: common + ["--endpoint", "--explain"]),
                            CommandNode(
                                "answer", "Answer a question it asked.",
                                options: common + ["--endpoint"], arguments: [.free, .free]),
                            CommandNode(
                                "skip", "Pass on a question.",
                                options: common + ["--endpoint"], arguments: [.free]),
                            CommandNode(
                                "mute", "Never be asked about a topic again.",
                                options: common + ["--endpoint"], arguments: [.free]),
                            CommandNode(
                                "ls", "Every question queued, asked or dropped.",
                                options: common + ["--endpoint", "--limit"]),
                        ]),
                    CommandNode(
                        "entities", "The people, projects and places it knows.",
                        options: common + ["--endpoint", "--limit"]),
                    CommandNode(
                        "eval", "Score the friend layer against the cases it should fail.",
                        children: [
                            CommandNode(
                                "run", "Run the suite now and print every case.",
                                options: common + ["--endpoint", "--persona"]),
                            CommandNode(
                                "ls", "Past eval runs.",
                                options: common + ["--endpoint", "--limit"]),
                        ]),
                    CommandNode(
                        "standup", "Record a standup and see what they add up to.",
                        children: [
                            CommandNode(
                                "record", "Record a standup, optionally verified.",
                                options: common + ["--endpoint", "--verify"],
                                arguments: [.localPath]),
                            CommandNode(
                                "report", "What your standups have added up to.",
                                options: common + ["--endpoint"]),
                        ]),
                    CommandNode(
                        "machines", "Where the companion stack runs.",
                        children: [
                            CommandNode(
                                "ls", "Every machine registered, and what was found.",
                                options: common + ["--endpoint"]),
                            CommandNode(
                                "add", "Register a machine the stack could run on.",
                                options: common + ["--endpoint", "--transport", "--at"],
                                arguments: [.free]),
                            CommandNode(
                                "probe", "Ask a machine what it is rather than assuming.",
                                options: common + ["--endpoint"], arguments: [.free]),
                            CommandNode(
                                "plan", "What would run where, before anything starts.",
                                options: common + ["--endpoint"]),
                            CommandNode(
                                "profile", "Override the tier a machine was given.",
                                options: common + ["--endpoint"], arguments: [.free, .free]),
                        ]),
                    CommandNode(
                        "baselines", "Your own delivery baselines.",
                        options: common + ["--endpoint"]),
                    CommandNode(
                        "connectors", "The tokens the behavioural connectors run on.",
                        children: [
                            CommandNode(
                                "show", "Which connectors have a token.",
                                options: common + ["--endpoint"]),
                            CommandNode(
                                "set", "Store a connector token on the companion.",
                                options: common + ["--endpoint", "--github", "--notion"]),
                            CommandNode(
                                "import", "Import a calendar, music or YouTube export.",
                                options: common + ["--endpoint"],
                                arguments: [.free, .localPath]),
                        ]),
                    CommandNode(
                        "facts", "What was true, and what it believed at the time.",
                        options: common + ["--endpoint", "--as-of", "--timeline", "--limit"]),
                    CommandNode(
                        "correct", "Retire a wrong belief, or rewrite it yourself.",
                        options: common + ["--endpoint", "--retire", "--edit"],
                        arguments: [.free]),
                    CommandNode(
                        "weekly", "The wider weekly pass over the beliefs.",
                        options: common + ["--endpoint"]),
                    CommandNode(
                        "db", "Migrate, reindex, or rebuild what is derived.",
                        children: [
                            CommandNode(
                                "migrate", "Apply any migrations not yet run.",
                                options: common + ["--endpoint"]),
                            CommandNode(
                                "reindex", "Drop the chunks so episodes embed again.",
                                options: common + ["--endpoint"]),
                            CommandNode(
                                "rebuild-derived", "Rebuild everything from the episodes.",
                                options: common + ["--endpoint"]),
                        ]),
                    CommandNode(
                        "chat", "Talk with the companion, streamed as it thinks.",
                        options: common + ["--endpoint", "--conversation"], arguments: [.free]),
                    CommandNode(
                        "conversations", "List chats, or replay one by id.",
                        options: common + ["--endpoint", "--limit"], arguments: [.free]),
                    CommandNode(
                        "forget", "Delete a conversation and its messages.",
                        options: common + ["--endpoint"], arguments: [.free]),
                    CommandNode(
                        "extract", "Pull typed claims out of recent episodes.",
                        options: common + ["--endpoint"]),
                    CommandNode(
                        "claims", "List the claims you have made, with verdicts.",
                        options: common + ["--endpoint", "--limit"]),
                    CommandNode(
                        "corroborate", "Check testable claims against the record.",
                        options: common + ["--endpoint"]),
                    CommandNode(
                        "runs", "List the background learning runs.",
                        options: common + ["--endpoint", "--limit"]),
                    CommandNode(
                        "nightly", "Run the nightly learning pipeline right now.",
                        options: common + ["--endpoint"]),
                    CommandNode(
                        "reason", "Show or change how the companion reasons.",
                        children: [
                            CommandNode(
                                "show", "Show the active reasoning provider.",
                                options: common + ["--endpoint"]),
                            CommandNode(
                                "set",
                                "Change the reasoning provider, model, URL, or API key.",
                                options: common
                                    + [
                                        "--endpoint", "--provider", "--model", "--url",
                                        "--api-key",
                                    ]),
                            CommandNode(
                                "test", "Round-trip one tiny completion through the reasoner.",
                                options: common + ["--endpoint"]),
                        ]),
                ]),
        ])

    public static var topLevelNames: [String] {
        root.children.flatMap(\.names)
    }

    public static func node(at path: [String]) -> CommandNode? {
        var current = root
        for name in path {
            guard let next = current.child(name) else { return nil }
            current = next
        }
        return current
    }
}
