import Foundation

public enum ArgumentKind: Equatable, Sendable {
    case machine
    case machineOrLocal
    case appAction
    case runningApp
    case appPath
    case appLink
    case guideTopic
    case cleanerCategory
    case colorFormat
    case colorIndex
    case pruneTarget
    case composeProject
    case historyIndex
    case shelfItem
    case shelfKeepDuration
    case musicTrack
    case calendarEvent
    case configKey
    case configValue
    case extensionID
    case toolID
    case permission
    case onOff
    case shell
    case group
    case usageRange
    case attentionRange
    case attentionEntity
    case attentionCategory
    case downloadKind
    case quinjetAppearance
    case quinjetMachine
    case quinjetPath
    case quinjetSession
    case quinjetTheme
    case localPath
    case musicPlayer
    case remotePath
    case container
    case tool
    case usageChat
    case usageProject
    case usageSource
    case free
}

public enum DestructivePolicy: String, Equatable, Sendable {
    case previewThenYes
}

public struct PassthroughCompletion: Equatable, Sendable {
    public let afterPositionals: Int
    public let remoteMachinePosition: Int?

    public init(afterPositionals: Int, remoteMachinePosition: Int? = nil) {
        self.afterPositionals = afterPositionals
        self.remoteMachinePosition = remoteMachinePosition
    }
}

public struct CommandNode: Equatable, Sendable {
    public let name: String
    public let summary: String
    public let aliases: [String]
    public let options: [String]
    public let optionValues: [String: ArgumentKind]
    public let arguments: [ArgumentKind]
    public let repeatingArgument: ArgumentKind?
    public let children: [CommandNode]
    public let destructivePolicy: DestructivePolicy?
    public let passthroughCompletion: PassthroughCompletion?

    public init(
        _ name: String, _ summary: String, aliases: [String] = [], options: [String] = [],
        optionValues: [String: ArgumentKind] = [:], arguments: [ArgumentKind] = [],
        repeatingArgument: ArgumentKind? = nil, children: [CommandNode] = [],
        destructivePolicy: DestructivePolicy? = nil,
        passthroughCompletion: PassthroughCompletion? = nil
    ) {
        self.name = name
        self.summary = summary
        self.aliases = aliases
        self.options = options
        self.optionValues = optionValues
        self.arguments = arguments
        self.repeatingArgument = repeatingArgument
        self.children = children
        self.destructivePolicy = destructivePolicy
        self.passthroughCompletion = passthroughCompletion
    }

    public var names: [String] { [name] + aliases }

    public func child(_ name: String) -> CommandNode? {
        children.first { $0.names.contains(name) }
    }
}

public enum CommandTree {
    public static let inherited = ["-h", "--help", "--version"]
    public static let common = ["--json"] + inherited
    public static let playback = ["--json", "--help", "--player"]
    public static let playbackValues: [String: ArgumentKind] = ["--player": .musicPlayer]
    public static let usageValues: [String: ArgumentKind] = [
        "--range": .usageRange, "--source": .usageSource, "--machine": .machine,
    ]
    public static let help = CommandNode(
        "help", "Show detailed help for a command.", arguments: [.free])

    public static let root = CommandNode(
        "ed", "The command line for Edith.", options: ["--help", "--version"],
        children: [
            CommandNode(
                "guide", "Print the built-in manual.", options: ["--json"],
                arguments: [.guideTopic]),
            CommandNode("schema", "Print the JSON Schema for the config document.", options: []),
            CommandNode("version", "Print the Edith CLI version.", options: common),
            CommandNode(
                "status", "Inspect command-line tools and shell completions.", options: common),
            CommandNode(
                "completions", "Generate or install shell completions.",
                children: [
                    CommandNode(
                        "install", "Install completions for the detected shells.",
                        options: ["--json", "--shell"], optionValues: ["--shell": .shell]),
                    CommandNode(
                        "source", "Print a fallback completion source line.",
                        options: ["--json", "--shell"], optionValues: ["--shell": .shell]),
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
                        options: ["--json", "--group", "--changed"],
                        optionValues: ["--group": .group]),
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
                    CommandNode("info", "Show the installed app identity.", options: common),
                    CommandNode(
                        "diagnostics", "Show live helper diagnostics.", options: common),
                    CommandNode("paths", "List Edith folders and files.", options: common),
                    CommandNode("links", "List Edith external links.", options: common),
                    CommandNode(
                        "open-path", "Open or reveal one Edith path.", options: common,
                        arguments: [.appPath]),
                    CommandNode(
                        "open-link", "Open one Edith external link.", options: common,
                        arguments: [.appLink]),
                    CommandNode(
                        "actions", "List the one-shot actions.", aliases: ["ls"],
                        options: common),
                    CommandNode("clean-keys", "Lock the keyboard for wiping.", options: common),
                    CommandNode(
                        "test-notification", "Send a test notification.", options: common),
                    CommandNode("open", "Open Edith's panel.", options: common),
                    CommandNode(
                        "quit", "Quit the Edith main window.",
                        options: ["--json", "--help", "--yes"],
                        destructivePolicy: .previewThenYes),
                    CommandNode(
                        "check-updates", "Check for an update now.",
                        options: ["--json", "--help", "--no-wait"]),
                    CommandNode(
                        "updates", "The update checks already made.",
                        options: ["--json", "--help", "--limit"]),
                    CommandNode(
                        "relaunch", "Quit Edith and start it again.",
                        options: ["--json", "--help", "--yes"],
                        destructivePolicy: .previewThenYes),
                    CommandNode(
                        "clear-updates", "Forget the record of past update checks.",
                        options: ["--json", "--help", "--yes"],
                        destructivePolicy: .previewThenYes),
                    CommandNode(
                        "reveal", "Show a section of the main window.",
                        options: ["--json", "--help", "--tab"]),
                    CommandNode(
                        "snapshot", "Capture the open windows as PNG files.",
                        options: ["--json", "--help", "--dir"]),
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
                    CommandNode(
                        "status", "Check extension readiness.", options: common,
                        arguments: [.extensionID]),
                    CommandNode(
                        "setup", "Enable an extension and report remaining setup.",
                        options: ["--json", "--help", "--dry-run", "--install-tools"],
                        arguments: [.extensionID]),
                    CommandNode(
                        "verify", "Run readiness checks for one extension.", options: common,
                        arguments: [.extensionID]),
                    CommandNode(
                        "doctor", "Diagnose extension problems.", options: common,
                        arguments: [.extensionID]),
                ]),
            CommandNode(
                "lid-awake", "Keep the Mac running with its lid closed.",
                children: [
                    CommandNode("status", "Show the live state.", options: common),
                    CommandNode(
                        "on", "Keep running with the lid closed.", aliases: ["start"],
                        options: ["--json", "--help", "--for", "--until-lid-reopens", "--yes"],
                        destructivePolicy: .previewThenYes),
                    CommandNode(
                        "off", "Restore normal lid-close sleep.", aliases: ["stop"],
                        options: common),
                    CommandNode(
                        "battery", "Set low-battery auto-pause.", options: common,
                        arguments: [.free]),
                    CommandNode(
                        "restore-on-quit", "Choose whether quitting restores sleep.",
                        options: ["--json", "--help", "--yes"], arguments: [.free],
                        destructivePolicy: .previewThenYes),
                ]),
            CommandNode(
                "display", "Control display brightness and sleep power behavior.",
                children: [
                    CommandNode("status", "Show displays and power behavior.", options: common),
                    CommandNode(
                        "brightness", "Set display brightness.",
                        options: ["--json", "--help", "--display"],
                        optionValues: ["--display": .free], arguments: [.free]),
                    CommandNode(
                        "xdr", "Set extra XDR brightness.", options: common,
                        arguments: [.free]),
                    CommandNode(
                        "bluetooth-sleep", "Turn Bluetooth off only while sleeping.",
                        options: common, arguments: [.onOff]),
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
                    CommandNode(
                        "settings", "Open System Settings for a permission.",
                        options: ["--json"], arguments: [.permission]),
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
                        optionValues: usageValues),
                    CommandNode(
                        "daily", "Per-day cost and tokens.",
                        options: ["--json", "--range", "--source", "--machine"],
                        optionValues: usageValues),
                    CommandNode(
                        "models", "Cost and tokens per model.",
                        options: ["--json", "--range", "--source", "--machine"],
                        optionValues: usageValues),
                    CommandNode(
                        "projects", "Inspect usage by GitHub repository.",
                        children: [
                            CommandNode(
                                "list", "List usage grouped by repository.",
                                options: ["--json", "--range", "--limit"],
                                optionValues: ["--range": .usageRange]),
                            CommandNode(
                                "show", "Show one repository and its usage hierarchy.",
                                options: ["--json", "--range"],
                                optionValues: ["--range": .usageRange],
                                arguments: [.usageProject]),
                            CommandNode(
                                "open", "Open a usage repository in the browser.",
                                options: ["--json", "--range"],
                                optionValues: ["--range": .usageRange],
                                arguments: [.usageProject]),
                            CommandNode(
                                "copy-link", "Copy a usage repository link.",
                                options: ["--json", "--range"],
                                optionValues: ["--range": .usageRange],
                                arguments: [.usageProject]),
                            CommandNode(
                                "copy-chat", "Copy a usage chat identifier.",
                                options: common, arguments: [.usageChat]),
                        ]),
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
                        options: ["--json", "-f", "--follow", "--interval", "--processes"]),
                    CommandNode("disks", "Mounted volumes and their free space.", options: common),
                ]),
            CommandNode(
                "music", "Whatever is playing, and playback control.",
                aliases: ["nowplaying", "np"], options: playback,
                optionValues: playbackValues,
                children: [
                    CommandNode(
                        "status", "What is playing right now.", options: playback,
                        optionValues: playbackValues),
                    CommandNode("players", "Every player, and which is active.", options: common),
                    CommandNode(
                        "play", "Resume playback.", options: playback,
                        optionValues: playbackValues),
                    CommandNode(
                        "pause", "Pause playback.", options: playback,
                        optionValues: playbackValues),
                    CommandNode(
                        "stop", "Stop playback and reset the position.", options: playback,
                        optionValues: playbackValues),
                    CommandNode(
                        "toggle", "Toggle play and pause.", aliases: ["playpause"],
                        options: playback, optionValues: playbackValues),
                    CommandNode(
                        "next", "Skip to the next track.", options: playback,
                        optionValues: playbackValues),
                    CommandNode(
                        "previous", "Go back to the previous track.", aliases: ["prev"],
                        options: playback, optionValues: playbackValues),
                    CommandNode(
                        "volume", "Set the player volume from 0 to 1.", options: playback,
                        optionValues: playbackValues),
                    CommandNode(
                        "open-current", "Open the active music player.", options: playback,
                        optionValues: playbackValues),
                    CommandNode(
                        "reveal-current", "Reveal the current track or open its player.",
                        options: playback, optionValues: playbackValues),
                    CommandNode(
                        "library", "Choose the folder Edith uses as its music library.",
                        options: common, arguments: [.localPath]),
                    CommandNode(
                        "start", "Play one track, or a whole folder.",
                        options: ["--json", "--help", "--folder"], arguments: [.free]),
                    CommandNode(
                        "favorite", "Add a track to favourites.", aliases: ["favourite"],
                        options: common, arguments: [.musicTrack]),
                    CommandNode(
                        "unfavorite", "Remove a track from favourites.",
                        aliases: ["unfavourite"], options: common, arguments: [.musicTrack]),
                    CommandNode(
                        "reveal", "Reveal a track in Finder.", options: common,
                        arguments: [.musicTrack]),
                    CommandNode("open", "Open the music library in Finder.", options: common),
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
                        options: ["--json", "--help", "--folder", "--yes"], arguments: [.free],
                        destructivePolicy: .previewThenYes),
                ]),
            CommandNode(
                "calendar", "Your schedule.",
                children: [
                    CommandNode(
                        "ls", "Upcoming events.", aliases: ["list"],
                        options: ["--json", "--days"]),
                    CommandNode("open", "Open Calendar.", options: common),
                    CommandNode(
                        "join", "Join an event's meeting.", options: common,
                        arguments: [.calendarEvent]),
                    CommandNode(
                        "directions", "Open directions to an event.", aliases: ["route"],
                        options: common, arguments: [.calendarEvent]),
                ]),
            CommandNode(
                "presenter", "Manual presenter mode at runtime.",
                children: [
                    CommandNode("status", "Show presenter runtime state.", options: common),
                    CommandNode("start", "Start manual presenter mode.", options: common),
                    CommandNode("stop", "Stop manual presenter mode.", options: common),
                ]),
            CommandNode(
                "herdr", "Live Herdr sessions on this Mac and your SSH machines.",
                children: [
                    CommandNode(
                        "ls", "List live Herdr sessions.", aliases: ["list"],
                        options: common + ["--machine"]),
                    CommandNode(
                        "command", "Print the command that attaches to a pane.",
                        options: common + ["--machine", "--session"],
                        arguments: [.free]),
                    CommandNode(
                        "attach", "Attach this terminal to a live pane.",
                        options: common + ["--machine", "--session"],
                        arguments: [.free]),
                ]),
            CommandNode(
                "tools", "Command line tools the extensions rely on.",
                children: [
                    CommandNode(
                        "ls", "List the tools and whether they are installed.",
                        aliases: ["list"], options: common),
                    CommandNode(
                        "install", "Install one of the tools.", options: common,
                        arguments: [.tool]),
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
                        arguments: [.runningApp], destructivePolicy: .previewThenYes),
                ]),
            CommandNode(
                "download", "The download queue Edith feeds to yt-dlp.",
                aliases: ["downloads", "dl"],
                children: [
                    CommandNode(
                        "ls", "List the queue.", aliases: ["list"],
                        options: ["--json", "--help", "--active", "--limit"]),
                    CommandNode("status", "Summarize download states.", options: common),
                    CommandNode(
                        "add", "Queue one or more URLs.",
                        options: ["--json", "--help", "--kind", "--prefix"],
                        optionValues: ["--kind": .downloadKind], arguments: [.free]),
                    CommandNode(
                        "retry", "Queue a failed download again.",
                        options: ["--json", "--help", "--all"], arguments: [.historyIndex]),
                    CommandNode(
                        "rm", "Take one entry out of the queue.",
                        options: common + ["--yes"],
                        arguments: [.historyIndex], destructivePolicy: .previewThenYes),
                    CommandNode(
                        "clear", "Forget what has finished.",
                        options: ["--json", "--help", "--yes"],
                        destructivePolicy: .previewThenYes),
                    CommandNode(
                        "cancel", "Stop active downloads and keep their history.", options: common,
                        arguments: [.historyIndex]),
                    CommandNode(
                        "open", "Open completed download files.", options: common,
                        arguments: [.historyIndex]),
                    CommandNode(
                        "reveal", "Reveal completed download files.", options: common,
                        arguments: [.historyIndex]),
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
                        "rm", "Forget one entry.", options: ["--json", "--help", "--yes"],
                        arguments: [.historyIndex], destructivePolicy: .previewThenYes),
                    CommandNode(
                        "clear", "Forget the whole history.",
                        options: ["--json", "--help", "--keep-pinned", "--yes"],
                        destructivePolicy: .previewThenYes),
                ]),
            CommandNode(
                "attention", "Local attention, application, website, music and focus data.",
                children: [
                    CommandNode("status", "Show tracking, data and focus state.", options: common),
                    CommandNode(
                        "summary", "Summarize focus, distraction and top destinations.",
                        options: ["--json", "--help", "--range"],
                        optionValues: ["--range": .attentionRange]),
                    CommandNode(
                        "timeline", "List raw observed attention events.",
                        options: ["--json", "--help", "--range", "--limit"],
                        optionValues: ["--range": .attentionRange]),
                    CommandNode(
                        "music", "Summarize tracks, artists, albums and listening time.",
                        options: ["--json", "--help", "--range", "--limit"],
                        optionValues: ["--range": .attentionRange]),
                    CommandNode(
                        "categories", "List categories or classify an entity.",
                        children: [
                            CommandNode(
                                "ls", "List categories and identity rules.", aliases: ["list"],
                                options: common),
                            CommandNode(
                                "set", "Assign an entity ID to a category.",
                                options: ["--json", "--help", "--name"],
                                arguments: [.attentionEntity, .attentionCategory]),
                        ]),
                    CommandNode(
                        "focus", "Start, inspect or finish a focus session.",
                        children: [
                            CommandNode(
                                "status", "Show the active focus session.", options: common),
                            CommandNode(
                                "start", "Start a named focus session.",
                                options: ["--json", "--help", "--for", "--name"]),
                            CommandNode(
                                "stop", "Finish the active focus session.", aliases: ["end"],
                                options: common),
                        ]),
                    CommandNode(
                        "doctor", "Check collectors, data and extension files.", options: common),
                ]),
            CommandNode(
                "color", "The colours picked with the colour picker.", aliases: ["colour"],
                children: [
                    CommandNode(
                        "pick", "Open Edith's system colour sampler.", options: common),
                    CommandNode(
                        "copy", "Copy one picked colour to the pasteboard.",
                        options: ["--json", "--help", "--format"],
                        optionValues: ["--format": .colorFormat], arguments: [.colorIndex]),
                    CommandNode(
                        "ls", "List picked colours.", aliases: ["list"],
                        options: ["--json", "--help", "--format", "--limit"],
                        optionValues: ["--format": .colorFormat]),
                    CommandNode(
                        "clear", "Forget every picked colour.",
                        options: ["--json", "--yes"], destructivePolicy: .previewThenYes),
                ]),
            CommandNode(
                "shelf", "The files parked on the notch shelf.",
                children: [
                    CommandNode(
                        "ls", "List what is on the shelf.", aliases: ["list"], options: common),
                    CommandNode(
                        "path", "Print the path of one item.", options: common,
                        arguments: [.shelfItem]),
                    CommandNode(
                        "add", "Copy a file onto the shelf.", options: ["--json"],
                        arguments: [.localPath]),
                    CommandNode(
                        "add-text", "Add text to the shelf.", options: common,
                        arguments: [.free]),
                    CommandNode(
                        "update", "Update one shelf item's canvas position.",
                        options: ["--json", "--help", "--x", "--y"], arguments: [.shelfItem]),
                    CommandNode(
                        "rm", "Take selected items off the shelf.",
                        options: ["--json", "--yes"],
                        arguments: [.shelfItem], repeatingArgument: .shelfItem,
                        destructivePolicy: .previewThenYes),
                    CommandNode(
                        "clear", "Empty the shelf.", options: ["--json", "--yes"],
                        destructivePolicy: .previewThenYes),
                    CommandNode(
                        "purge", "Remove shelf items past an expiry window.",
                        options: ["--json", "--yes"], arguments: [.shelfKeepDuration],
                        destructivePolicy: .previewThenYes),
                    CommandNode(
                        "open", "Open selected shelf items.", options: common,
                        arguments: [.shelfItem], repeatingArgument: .shelfItem),
                    CommandNode(
                        "reveal", "Reveal selected shelf items in Finder.", options: common,
                        arguments: [.shelfItem], repeatingArgument: .shelfItem),
                    CommandNode(
                        "share", "Open sharing for selected shelf items.", options: common,
                        arguments: [.shelfItem], repeatingArgument: .shelfItem),
                ]),
            CommandNode(
                "cleaner", "The developer caches the disk cleaner can reclaim.",
                children: [
                    CommandNode(
                        "scan", "Measure what could be reclaimed.",
                        options: ["--json", "--help", "--category", "--root"],
                        optionValues: ["--category": .cleanerCategory]),
                    CommandNode(
                        "categories", "The caches the cleaner knows.", aliases: ["ls"],
                        options: common),
                    CommandNode(
                        "clean", "Move the scanned caches to the Trash.",
                        options: ["--json", "--help", "--category", "--root", "--yes"],
                        optionValues: ["--category": .cleanerCategory],
                        destructivePolicy: .previewThenYes),
                    CommandNode("drives", "The volumes the cleaner can scan.", options: common),
                ]),
            CommandNode(
                "quinjet", "Discover and open Quinjet review workspaces.",
                children: [
                    CommandNode(
                        "projects", "List recent Quinjet projects.",
                        options: ["--json", "--help", "--machine"],
                        optionValues: ["--machine": .quinjetMachine]),
                    CommandNode(
                        "worktrees", "List the worktrees in a Quinjet project.",
                        options: ["--json", "--help", "--machine"],
                        optionValues: ["--machine": .quinjetMachine],
                        arguments: [.quinjetPath]),
                    CommandNode(
                        "open", "Print a Quinjet launch request without running it.",
                        options: [
                            "--json", "--help", "--machine", "--theme", "--appearance",
                            "--cmux", "--embedded",
                        ],
                        optionValues: [
                            "--machine": .quinjetMachine, "--theme": .quinjetTheme,
                            "--appearance": .quinjetAppearance,
                        ], arguments: [.quinjetPath]),
                    CommandNode(
                        "launch", "Launch a Quinjet review session.",
                        options: [
                            "--json", "--help", "--machine", "--theme", "--appearance",
                            "--cmux", "--embedded",
                        ],
                        optionValues: [
                            "--machine": .quinjetMachine, "--theme": .quinjetTheme,
                            "--appearance": .quinjetAppearance,
                        ],
                        arguments: [.quinjetPath]),
                    CommandNode(
                        "status", "Show the selected native Quinjet session.",
                        options: common, arguments: [.quinjetSession]),
                    CommandNode(
                        "sessions", "List native Quinjet sessions in the running app.",
                        aliases: ["list", "ls"], options: common),
                    CommandNode(
                        "new", "Create and select a native Quinjet session.",
                        aliases: ["create"], options: common),
                    CommandNode(
                        "focus", "Select and focus a native Quinjet session.",
                        aliases: ["select"], options: common, arguments: [.quinjetSession]),
                    CommandNode(
                        "close", "Close a native Quinjet session.",
                        options: ["--json", "--help", "--yes"],
                        arguments: [.quinjetSession], destructivePolicy: .previewThenYes),
                    CommandNode(
                        "restart", "Restart a native Quinjet session in place.",
                        options: common, arguments: [.quinjetSession]),
                    CommandNode(
                        "switch", "Switch a native Quinjet session to another worktree.",
                        options: common, arguments: [.quinjetSession, .quinjetPath]),
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
                            "--alias", "--mac", "--password-stdin", "--key-passphrase-stdin",
                        ],
                        arguments: [.free]),
                    CommandNode(
                        "edit", "Change a machine already on the list.",
                        options: [
                            "--json", "--help", "--name", "--host", "--port", "--user",
                            "--key", "--agent", "--mac", "--sudo-password-stdin",
                            "--forget-sudo-password", "--password-stdin", "--key-passphrase-stdin",
                        ],
                        arguments: [.machine]),
                    CommandNode(
                        "rm", "Forget a machine and everything saved against it.",
                        aliases: ["remove"], options: ["--json", "--help", "--yes"],
                        arguments: [.machine], destructivePolicy: .previewThenYes),
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
                                "open", "Open a forwarded service in the browser.",
                                options: common, arguments: [.machine, .historyIndex]),
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
                                arguments: [.machine, .free, .free],
                                passthroughCompletion: PassthroughCompletion(
                                    afterPositionals: 2)),
                            CommandNode(
                                "rm", "Forget one snippet.", aliases: ["remove"],
                                options: common, arguments: [.machine, .historyIndex]),
                            CommandNode(
                                "run", "Run one saved command on a machine.", options: common,
                                arguments: [.machine, .historyIndex]),
                        ]),
                    CommandNode(
                        "power", "Restart, shut down or wake a machine.",
                        children: [
                            CommandNode(
                                "status", "Whether a machine is up and what it can be told.",
                                options: common, arguments: [.machine]),
                            CommandNode(
                                "reboot", "Restart a machine.", aliases: ["restart"],
                                options: ["--json", "--help", "--yes"], arguments: [.machine],
                                destructivePolicy: .previewThenYes),
                            CommandNode(
                                "shutdown", "Shut a machine down.", aliases: ["poweroff"],
                                options: ["--json", "--help", "--yes"], arguments: [.machine],
                                destructivePolicy: .previewThenYes),
                            CommandNode(
                                "wake", "Send a wake-on-LAN packet.", options: common,
                                arguments: [.machine]),
                        ]),
                    CommandNode(
                        "thermal", "Inspect and switch the platform thermal profile.",
                        children: [
                            CommandNode(
                                "status", "Show the active and available thermal profiles.",
                                options: common, arguments: [.machine]),
                            CommandNode(
                                "set", "Switch the thermal profile permanently or for a while.",
                                options: ["--json", "--help", "--minutes"],
                                arguments: [.machine, .free]),
                        ]),
                    CommandNode(
                        "control", "Inspect and change live machine controls.",
                        children: [
                            CommandNode(
                                "status", "Read the available live controls.",
                                options: common, arguments: [.machine]),
                            CommandNode(
                                "brightness", "Set display brightness.", options: common,
                                arguments: [.machine, .free]),
                            CommandNode(
                                "volume", "Set system output volume.", options: common,
                                arguments: [.machine, .free]),
                            CommandNode(
                                "mute", "Mute or unmute system audio.", options: common,
                                arguments: [.machine, .onOff]),
                            CommandNode(
                                "wifi", "Turn Wi-Fi on or off.",
                                options: ["--json", "--help", "--yes"],
                                arguments: [.machine, .onOff],
                                destructivePolicy: .previewThenYes),
                            CommandNode(
                                "bluetooth", "Turn Bluetooth on or off.", options: common,
                                arguments: [.machine, .onOff]),
                            CommandNode(
                                "airplane", "Turn airplane mode on or off.",
                                options: ["--json", "--help", "--yes"],
                                arguments: [.machine, .onOff],
                                destructivePolicy: .previewThenYes),
                            CommandNode(
                                "dnd", "Turn Do Not Disturb on or off.", options: common,
                                arguments: [.machine, .onOff]),
                            CommandNode(
                                "keyboard-light", "Set keyboard backlight brightness.",
                                options: common, arguments: [.machine, .free]),
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
                        "terminal", "Act on terminal tabs that are open in the Edith app.",
                        children: [
                            CommandNode(
                                "broadcast",
                                "Send one line to every open terminal tab for one machine.",
                                options: common, arguments: [.machineOrLocal, .free])
                        ]),
                    CommandNode(
                        "kill", "End a process on a machine.",
                        options: ["--json", "--help", "--signal", "--yes"],
                        arguments: [.machine, .historyIndex],
                        destructivePolicy: .previewThenYes),
                    CommandNode(
                        "metrics", "Sample a machine.",
                        options: ["--json", "-f", "--follow", "--interval", "--processes"],
                        arguments: [.machine]),
                    CommandNode(
                        "exec", "Run a command on a machine.", aliases: ["run"],
                        options: ["-t", "--tty"],
                        arguments: [.machine, .free],
                        passthroughCompletion: PassthroughCompletion(
                            afterPositionals: 1, remoteMachinePosition: 0)),
                    CommandNode(
                        "files", "Browse and transfer files.",
                        children: [
                            CommandNode(
                                "ls", "List a remote directory.", aliases: ["list"],
                                options: ["--json", "--help", "-a", "--all"],
                                arguments: [.machine, .remotePath]),
                            CommandNode(
                                "get", "Download a file.",
                                options: ["--json", "--help", "--dry-run", "--replace", "--yes"],
                                arguments: [.machine, .remotePath, .localPath],
                                destructivePolicy: .previewThenYes),
                            CommandNode(
                                "preview", "Print a text preview of a remote file.",
                                options: common, arguments: [.machine, .remotePath]),
                            CommandNode(
                                "launch", "Open a remote file in its default Mac app.",
                                options: common, arguments: [.machine, .remotePath]),
                            CommandNode(
                                "reveal", "Reveal a downloaded remote file in Finder.",
                                options: common, arguments: [.machine, .remotePath]),
                            CommandNode(
                                "get-many", "Download multiple files.",
                                options: [
                                    "--json", "--help", "--dry-run", "--replace", "--yes", "--to",
                                ], optionValues: ["--to": .localPath],
                                arguments: [.machine, .remotePath],
                                repeatingArgument: .remotePath,
                                destructivePolicy: .previewThenYes),
                            CommandNode(
                                "transfer", "Transfer files between two machines.",
                                options: [
                                    "--json", "--help", "--dry-run", "--replace", "--yes", "--into",
                                ], optionValues: ["--into": .remotePath],
                                arguments: [.machine, .machine, .remotePath],
                                repeatingArgument: .remotePath,
                                destructivePolicy: .previewThenYes),
                            CommandNode(
                                "put", "Upload a file.",
                                options: ["--json", "--help", "--dry-run", "--replace", "--yes"],
                                arguments: [.machine, .localPath, .remotePath],
                                destructivePolicy: .previewThenYes),
                            CommandNode(
                                "cp", "Copy files into a directory there.",
                                options: ["--json", "--help", "--dry-run", "--replace", "--yes"],
                                arguments: [.machine, .remotePath],
                                repeatingArgument: .remotePath,
                                destructivePolicy: .previewThenYes),
                            CommandNode(
                                "mv", "Move files into a directory there.",
                                options: ["--json", "--help", "--dry-run", "--replace", "--yes"],
                                arguments: [.machine, .remotePath],
                                repeatingArgument: .remotePath,
                                destructivePolicy: .previewThenYes),
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
                                arguments: [.machine, .remotePath],
                                destructivePolicy: .previewThenYes),
                        ]),
                    CommandNode(
                        "docker", "Containers on a machine.",
                        children: [
                            CommandNode(
                                "shell", "Open an interactive shell in a container.",
                                arguments: [.machine, .container]),
                            CommandNode(
                                "ps", "List containers.", options: ["--json", "-a", "--all"],
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
                                options: ["--tail", "-f", "--follow"],
                                arguments: [.machine, .container]),
                            CommandNode(
                                "inspect", "Inspect a container with stable fields.",
                                options: common,
                                arguments: [.machine, .container]),
                            CommandNode(
                                "top", "Read processes running in a container.", options: common,
                                arguments: [.machine, .container]),
                            CommandNode(
                                "open", "Open a published container port in the browser.",
                                options: ["--json", "--help", "--port"],
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
                                "rm", "Remove a container.", options: ["--json", "--yes"],
                                arguments: [.machine, .container],
                                destructivePolicy: .previewThenYes),
                            CommandNode(
                                "pause", "Freeze a container.", options: ["--json"],
                                arguments: [.machine, .container]),
                            CommandNode(
                                "unpause", "Let a frozen container run.", options: ["--json"],
                                arguments: [.machine, .container]),
                            CommandNode(
                                "rmi", "Remove an image.", aliases: ["remove-image"],
                                options: ["--json", "--help", "--force", "--yes"],
                                arguments: [.machine, .free],
                                destructivePolicy: .previewThenYes),
                            CommandNode(
                                "volume-rm", "Remove a volume and the data in it.",
                                options: ["--json", "--help", "--yes"],
                                arguments: [.machine, .free],
                                destructivePolicy: .previewThenYes),
                            CommandNode(
                                "prune", "Reclaim space from unused objects.",
                                options: ["--json", "--help", "--yes"],
                                arguments: [.machine, .pruneTarget],
                                destructivePolicy: .previewThenYes),
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
                                        options: ["--tail", "-f", "--follow", "--help"],
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
                    CommandNode(
                        "mount-reveal", "Reveal a mounted machine file system in Finder.",
                        options: common, arguments: [.machine]),
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
                                options: common + ["--endpoint", "--yes"],
                                destructivePolicy: .previewThenYes),
                            CommandNode(
                                "rebuild-derived", "Rebuild everything from the episodes.",
                                options: common + ["--endpoint", "--yes"],
                                destructivePolicy: .previewThenYes),
                        ]),
                    CommandNode(
                        "chat", "Talk with the companion, streamed as it thinks.",
                        options: common + ["--endpoint", "--conversation", "--persona"],
                        arguments: [.free]),
                    CommandNode(
                        "conversations", "List chats, or replay one by id.",
                        options: common + ["--endpoint", "--limit"], arguments: [.free]),
                    CommandNode(
                        "forget", "Delete a conversation and its messages.",
                        options: common + ["--endpoint", "--yes"], arguments: [.free],
                        destructivePolicy: .previewThenYes),
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
                    CommandNode(
                        "hosts", "Machines that could run the companion, and what each needs.",
                        options: common + ["--machine"]),
                    CommandNode(
                        "deploy", "Choose the machine that runs the companion.",
                        options: common + ["--directory", "--port", "--adopt"],
                        arguments: [.machine]),
                    CommandNode(
                        "stack", "Start, stop and inspect the companion stack on its host.",
                        children: [
                            CommandNode(
                                "status", "Which host runs the stack, and what is up.",
                                options: common),
                            CommandNode("up", "Start the stack.", options: common + ["--build"]),
                            CommandNode(
                                "down", "Stop the stack.",
                                options: common + ["--wipe", "--yes"],
                                destructivePolicy: .previewThenYes),
                            CommandNode("restart", "Restart the stack.", options: common),
                            CommandNode(
                                "logs", "Read the stack's logs.", options: common + ["--tail"],
                                arguments: [.free]),
                            CommandNode(
                                "env", "Print the environment the stack would be given.",
                                options: common + ["--reveal"]),
                        ]),
                    CommandNode(
                        "export", "Save everything remembered as a restorable bundle.",
                        options: common + ["--endpoint", "--include-media"],
                        arguments: [.localPath]),
                    CommandNode(
                        "import", "Restore a bundle written by export.",
                        options: common + ["--endpoint"], arguments: [.localPath]),
                    CommandNode(
                        "erase", "Delete one episode and everything derived from it.",
                        options: common + ["--endpoint", "--yes"], arguments: [.free],
                        destructivePolicy: .previewThenYes),
                    CommandNode(
                        "wipe", "Delete the companion's entire memory.",
                        options: common + ["--endpoint", "--yes"],
                        destructivePolicy: .previewThenYes),
                ]),
        ])

    public static var topLevelNames: [String] {
        root.children.flatMap(\.names) + help.names
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
