import Foundation

public enum ExtensionLifecyclePhase: String, CaseIterable, Codable, Sendable {
    case disabled
    case checking
    case needsSetup
    case enabled
    case ready
    case degraded
    case unavailable
    case failed

    public var title: String {
        switch self {
        case .disabled: "Disabled"
        case .checking: "Checking"
        case .needsSetup: "Needs setup"
        case .enabled: "Enabled"
        case .ready: "Ready"
        case .degraded: "Degraded"
        case .unavailable: "Unavailable"
        case .failed: "Failed"
        }
    }
}

public enum ExtensionRuntimePhase: String, CaseIterable, Codable, Sendable {
    case installed
    case uninstalled
    case empty
    case loading
    case unsupported
    case error

    public var title: String {
        switch self {
        case .installed: "Installed"
        case .uninstalled: "Uninstalled"
        case .empty: "Empty"
        case .loading: "Loading"
        case .unsupported: "Unsupported"
        case .error: "Error"
        }
    }
}

public struct ExtensionLifecycleIssue: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let recoveryCommand: String?

    public init(id: String, title: String, detail: String, recoveryCommand: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.recoveryCommand = recoveryCommand
    }
}

public struct ExtensionLifecycleState: Codable, Equatable, Sendable {
    public let extensionID: String
    public let phase: ExtensionLifecyclePhase
    public let runtimePhase: ExtensionRuntimePhase
    public let summary: String
    public let issues: [ExtensionLifecycleIssue]

    public init(
        extensionID: String, phase: ExtensionLifecyclePhase,
        runtimePhase: ExtensionRuntimePhase = .installed, summary: String,
        issues: [ExtensionLifecycleIssue] = []
    ) {
        self.extensionID = extensionID
        self.phase = phase
        self.runtimePhase = runtimePhase
        self.summary = summary
        self.issues = issues
    }

    public static func preference(extensionID: String, enabled: Bool) -> Self {
        ExtensionLifecycleState(
            extensionID: extensionID, phase: enabled ? .enabled : .disabled,
            runtimePhase: .loading,
            summary: enabled ? "Enabled; readiness has not been checked." : "Disabled.")
    }

    public static func loading(extensionID: String) -> Self {
        ExtensionLifecycleState(
            extensionID: extensionID, phase: .checking, runtimePhase: .loading,
            summary: "Checking readiness.")
    }
}

public enum ExtensionLifecycleCheckStatus: String, CaseIterable, Codable, Sendable {
    case passed
    case warning
    case failed
    case skipped
}

public struct ExtensionLifecycleCheck: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let status: ExtensionLifecycleCheckStatus
    public let runtimePhase: ExtensionRuntimePhase?
    public let detail: String
    public let recoveryCommand: String?

    public init(
        id: String, title: String, status: ExtensionLifecycleCheckStatus,
        runtimePhase: ExtensionRuntimePhase? = nil, detail: String,
        recoveryCommand: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.runtimePhase = runtimePhase
        self.detail = detail
        self.recoveryCommand = recoveryCommand
    }
}

public struct ExtensionLifecycleReport: Codable, Equatable, Sendable {
    public let state: ExtensionLifecycleState
    public let checks: [ExtensionLifecycleCheck]

    public init(state: ExtensionLifecycleState, checks: [ExtensionLifecycleCheck]) {
        self.state = state
        self.checks = checks
    }

    public var verified: Bool { state.phase == .ready }
}
public struct ExtensionLifecycleInstruction: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let command: String?

    public init(id: String, title: String, detail: String, command: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.command = command
    }
}

public struct ExtensionDocumentationLink: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let path: String

    public init(id: String, title: String, path: String) {
        self.id = id
        self.title = title
        self.path = path
    }
}

public struct ExtensionLifecycleDescriptor: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let value: String
    public let workflows: [ExtensionLifecycleInstruction]
    public let prerequisites: [ExtensionLifecycleInstruction]
    public let cliExamples: [String]
    public let documentation: [ExtensionDocumentationLink]
    public let recovery: [ExtensionLifecycleInstruction]
    public let verification: [ExtensionLifecycleInstruction]

    public init(
        id: String, value: String, workflows: [ExtensionLifecycleInstruction],
        prerequisites: [ExtensionLifecycleInstruction], cliExamples: [String],
        documentation: [ExtensionDocumentationLink], recovery: [ExtensionLifecycleInstruction],
        verification: [ExtensionLifecycleInstruction]
    ) {
        self.id = id
        self.value = value
        self.workflows = workflows
        self.prerequisites = prerequisites
        self.cliExamples = cliExamples
        self.documentation = documentation
        self.recovery = recovery
        self.verification = verification
    }
}

public enum ExtensionLifecycleCatalog {
    public static let descriptors: [ExtensionLifecycleDescriptor] = {
        let order = Dictionary(
            uniqueKeysWithValues: ExtensionRegistry.entries.enumerated().map {
                ($0.element.id, $0.offset)
            })
        return
            allDescriptors
            .compactMap { descriptor in order[descriptor.id].map { (descriptor, $0) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }()

    public static let allDescriptors: [ExtensionLifecycleDescriptor] = [
        descriptor(
            "attention", "Understand app and browser activity, then protect focused work.",
            workflows: [
                instruction(
                    "timeline", "Review attention", "See focused, distracting, and idle time."),
                instruction(
                    "focus", "Run a focus session", "Set an intention and track the session."),
            ],
            prerequisites: [
                instruction(
                    "tracking", "Choose tracking sources",
                    "Enable application tracking, browser tracking, or both in Attention settings.")
            ],
            examples: [
                "ed extensions enable attention", "ed attention summary --json",
                "ed attention focus start --name Deep-work --for 45m",
            ],
            docs: [
                documentation("guide", "Attention guide", "docs/cli/attention/README.md")
            ],
            recovery: [
                instruction(
                    "doctor", "Check Attention readiness",
                    "Inspect the helper and tracking configuration.",
                    "ed extensions doctor attention --json")
            ],
            verification: [
                instruction(
                    "status", "Read the current summary",
                    "Confirm the Attention store is readable.", "ed attention summary --json")
            ]),
        descriptor(
            "usage", "See agent limits, cost and pacing before they interrupt your work.",
            workflows: [
                instruction("limits", "Watch limits", "Compare session and weekly headroom."),
                instruction("history", "Review usage", "Break down cost and tokens over time."),
            ],
            prerequisites: [
                instruction(
                    "provider", "Sign in to an agent CLI",
                    "Install and authenticate Claude Code, Codex, or both.",
                    "ed tools ls --json")
            ],
            examples: ["ed extensions enable usage", "ed usage limits --json"],
            docs: [documentation("guide", "Agent Usage guide", "docs/cli/usage/README.md")],
            recovery: [
                instruction(
                    "tools", "Repair provider tools", "Install a missing provider CLI.",
                    "ed tools ls")
            ],
            verification: [
                instruction(
                    "limits", "Read live limits", "Confirm at least one provider returns data.",
                    "ed usage limits --json")
            ]),
        descriptor(
            "herdr", "Jump into live local and remote Herdr sessions from one place.",
            workflows: [
                instruction(
                    "discover", "Find sessions",
                    "List active sessions across this Mac and SSH machines."),
                instruction(
                    "attach", "Resume work", "Generate the command that attaches to a pane."),
            ],
            prerequisites: [
                instruction(
                    "session", "Start Herdr",
                    "Install Herdr and run at least one session locally or remotely.",
                    "ed herdr ls --machine local")
            ],
            examples: ["ed extensions enable herdr", "ed herdr ls --json"],
            docs: [documentation("guide", "Herdr guide", "docs/cli/herdr/README.md")],
            recovery: [
                instruction(
                    "local", "Check this Mac",
                    "Confirm the local Herdr installation and live sessions.",
                    "ed herdr ls --machine local"),
                instruction(
                    "machines", "Check remote machines", "Verify saved SSH machines are reachable.",
                    "ed machines ls"),
            ],
            verification: [
                instruction(
                    "sessions", "List sessions", "Confirm Herdr reports the expected sessions.",
                    "ed herdr ls --json")
            ]),
        descriptor(
            "quinjet",
            "Review pull requests and follow live workspace changes without leaving Edith.",
            workflows: [
                instruction(
                    "review", "Review a pull request",
                    "Open a review workspace in an embedded terminal or cmux."),
                instruction(
                    "live", "Follow live changes",
                    "Keep the review synchronized with the active workspace."),
            ],
            prerequisites: [
                instruction(
                    "tool", "Install Quinjet", "Put the quinjet executable on Edith's PATH.",
                    "ed tools install quinjet"),
                instruction(
                    "repository", "Open a Git repository",
                    "Use a repository with a pull request or live workspace."),
            ],
            examples: ["ed extensions enable quinjet", "ed config set quinjetTerminal embedded"],
            docs: [documentation("guide", "Quinjet guide", "docs/quinjet.md")],
            recovery: [
                instruction(
                    "install", "Repair Quinjet", "Retry the managed Homebrew installation.",
                    "ed tools install quinjet"),
                instruction(
                    "terminal", "Use the embedded terminal",
                    "Switch back when cmux is unavailable.",
                    "ed config set quinjetTerminal embedded"),
            ],
            verification: [
                instruction(
                    "tool", "Verify Quinjet",
                    "Confirm the executable is installed and reports a version.",
                    "ed tools ls --json")
            ]),
        descriptor(
            "seoAudit",
            "Find every page in a sitemap and keep comparable search audits on this Mac.",
            workflows: [
                instruction(
                    "discover", "Discover pages",
                    "Read robots.txt and nested sitemap indexes before choosing pages."),
                instruction(
                    "audit", "Audit selected pages",
                    "Inspect metadata and optionally run Lighthouse for each selected URL."),
            ],
            prerequisites: [
                instruction(
                    "site", "Choose a site", "Use a reachable HTTP or HTTPS URL.",
                    "ed extensions enable seoAudit")
            ],
            examples: [
                "ed extensions enable seoAudit", "ed extensions doctor seoAudit --json",
            ],
            docs: [
                documentation(
                    "extensions", "Extensions guide", "docs/cli/extensions/README.md")
            ],
            recovery: [
                instruction(
                    "doctor", "Check Site Audit readiness",
                    "Verify the extension is enabled and supported on this Mac.",
                    "ed extensions doctor seoAudit --json")
            ],
            verification: [
                instruction(
                    "status", "Verify Site Audit",
                    "Confirm the local audit workspace is ready.",
                    "ed extensions doctor seoAudit --json")
            ]),
        descriptor(
            "system",
            "Control running apps, sleep prevention and keyboard cleaning from one panel.",
            workflows: [
                instruction(
                    "apps", "Manage applications",
                    "Inspect and quit applications with open windows."),
                instruction("sleep", "Prevent sleep", "Keep long-running work active when needed."),
            ],
            prerequisites: [
                instruction(
                    "access", "Grant optional system access",
                    "Accessibility and Input Monitoring unlock keyboard cleaning.",
                    "ed permissions ls --json")
            ],
            examples: ["ed extensions enable system", "ed apps ls --json"],
            docs: [documentation("guide", "System guide", "docs/cli/apps/README.md")],
            recovery: [
                instruction(
                    "permissions", "Refresh access", "Refresh mirrored macOS permission state.",
                    "ed permissions refresh")
            ],
            verification: [
                instruction(
                    "apps", "List applications", "Confirm running applications are visible.",
                    "ed apps ls --json")
            ]),
        descriptor(
            "appMaintenance",
            "Manage packages, installed applications, updates, and exact support files.",
            workflows: [
                instruction(
                    "packages", "Manage Homebrew packages",
                    "Browse, search, install, upgrade, and confirm package removal."),
                instruction(
                    "updates", "Review updates",
                    "Compare managed, store, and app-native updates before running a batch."),
                instruction(
                    "inventory", "Review installed apps",
                    "See versions and Homebrew update status for regular Applications folders."),
                instruction(
                    "remove", "Remove an app safely",
                    "Choose exact bundle-identifier matches and move only the selection to Trash."),
                instruction(
                    "install", "Install a disk image safely",
                    "Verify the single app in a disk image, stage it, install it and clean up recoverably."
                ),
            ],
            prerequisites: [
                instruction(
                    "access", "Use regular Applications folders",
                    "User-owned apps need no extra access. macOS may refuse protected or administrator-owned items."
                ),
                instruction(
                    "tool", "Install Homebrew for packages",
                    "Install Homebrew from brew.sh to use package discovery and management.",
                    "ed brew status --json"
                ),
            ],
            examples: [
                "ed extensions enable appMaintenance", "ed maintenance inventory --json",
                "ed maintenance updates --json", "ed maintenance update",
                "ed brew ls --outdated --json", "ed brew search ripgrep --kind formula --json",
                "ed maintenance scan /Applications/Example.app --json",
                "ed maintenance install ~/Downloads/Example.dmg --json",
            ],
            docs: [
                documentation("guide", "App Maintenance guide", "docs/app-maintenance.md"),
                documentation("packages", "Homebrew package guide", "docs/homebrew-manager.md"),
            ],
            recovery: [
                instruction(
                    "status", "Check Homebrew", "Confirm Homebrew is installed and callable.",
                    "ed brew status --json"),
                instruction(
                    "rescan", "Rescan a changed app",
                    "Build a fresh removal plan when an app changes after review.",
                    "ed maintenance scan /Applications/Example.app"),
                instruction(
                    "image", "Retry a changed disk image",
                    "Choose the download again, review it and explicitly retry installation.",
                    "ed maintenance install ~/Downloads/Example.dmg --yes"),
            ],
            verification: [
                instruction(
                    "packages", "Read installed packages",
                    "Confirm Homebrew metadata is available without changing packages.",
                    "ed brew ls --json"),
                instruction(
                    "inventory", "List installed apps",
                    "Confirm the Applications folders and optional Homebrew status are readable.",
                    "ed maintenance inventory --json"),
                instruction(
                    "installer", "Review an installer",
                    "Mount, verify, preview and eject a single-app disk image without installing it.",
                    "ed maintenance install ~/Downloads/Example.dmg --json"),
            ]),
        descriptor(
            "machines", "Operate SSH computers, files, services and containers from Edith.",
            workflows: [
                instruction(
                    "health", "Check machine health", "Inspect uptime, load, disks and services."),
                instruction(
                    "workspace", "Work remotely",
                    "Browse files, open terminals and manage containers."),
            ],
            prerequisites: [
                instruction(
                    "ssh", "Configure SSH", "Add a reachable host with working authentication.",
                    "ed machines add --help")
            ],
            examples: ["ed extensions enable machines", "ed machines ls --json"],
            docs: [documentation("guide", "Machines guide", "docs/cli/machines/README.md")],
            recovery: [
                instruction(
                    "show", "Diagnose a machine", "Resolve SSH or host configuration errors.",
                    "ed machines show --help")
            ],
            verification: [
                instruction(
                    "list", "List machines", "Confirm the expected hosts are configured.",
                    "ed machines ls --json")
            ]),
        descriptor(
            "database", "Explore and operate databases through a guarded local workbench.",
            workflows: [
                instruction(
                    "explore", "Explore database structure",
                    "Browse catalogs, schemas, collections, indexes and rows."),
                instruction(
                    "mutate", "Review changes before execution",
                    "Preview impact and confirm destructive operations exactly."),
            ],
            prerequisites: [
                instruction(
                    "connection", "Add a database connection",
                    "Open Database and configure a reachable database endpoint.")
            ],
            examples: [
                "ed extensions enable database", "ed extensions doctor database --json",
            ],
            docs: [
                documentation("extensions", "Extensions guide", "docs/cli/extensions/README.md")
            ],
            recovery: [
                instruction(
                    "doctor", "Check Database readiness",
                    "Inspect extension availability and local broker readiness.",
                    "ed extensions doctor database --json")
            ],
            verification: [
                instruction(
                    "status", "Verify the Database extension",
                    "Confirm the extension is enabled and available.",
                    "ed extensions status database --json")
            ]),
        descriptor(
            "companion", "Search and reason over your notes, activity and voice memories.",
            workflows: [
                instruction(
                    "capture", "Build memory",
                    "Ingest notes, recordings and activity into episodes."),
                instruction(
                    "ask", "Ask with context", "Search memories and inspect supporting evidence."),
            ],
            prerequisites: [
                instruction(
                    "backend", "Deploy or connect the backend",
                    "Choose a host and deploy Companion, or configure another endpoint.",
                    "ed companion deploy")
            ],
            examples: ["ed extensions enable companion", "ed companion status --json"],
            docs: [documentation("guide", "Companion guide", "docs/companion.md")],
            recovery: [
                instruction(
                    "doctor", "Diagnose Companion",
                    "Check the endpoint, database and supporting services.",
                    "ed companion doctor --json")
            ],
            verification: [
                instruction(
                    "status", "Check the backend",
                    "Confirm the configured Companion endpoint is healthy.",
                    "ed companion status --json")
            ]),
        descriptor(
            "systemStats", "Keep current CPU and memory pressure visible in the menu bar.",
            workflows: [
                instruction(
                    "glance", "Monitor the Mac",
                    "Watch live CPU and memory without opening a window.")
            ],
            prerequisites: [
                instruction(
                    "menu", "Show the menu bar helper",
                    "Allow Edith's menu bar item to remain visible.")
            ],
            examples: ["ed extensions enable systemStats", "ed system stats --json"],
            docs: [documentation("guide", "System metrics guide", "docs/cli/system/README.md")],
            recovery: [
                instruction(
                    "toggle", "Restart the readout",
                    "Reapply the extension preference so the helper synchronizes the readout.",
                    "ed extensions enable systemStats")
            ],
            verification: [
                instruction(
                    "sample", "Sample metrics", "Confirm CPU and memory data can be read.",
                    "ed system stats --json")
            ]),
        descriptor(
            "micMute", "Mute every microphone quickly from a shortcut or menu bar control.",
            workflows: [
                instruction(
                    "mute", "Control microphones", "Mute or restore all available input devices."),
                instruction(
                    "shortcut", "Act instantly", "Use the configured global shortcut from any app."),
            ],
            prerequisites: [
                instruction(
                    "input", "Connect an input device",
                    "Make at least one microphone available to macOS.")
            ],
            examples: ["ed extensions enable micMute", "ed config ls --group micmute --json"],
            docs: [
                documentation("extensions", "Extensions guide", "docs/cli/extensions/README.md")
            ],
            recovery: [
                instruction(
                    "state", "Reset extension state", "Disable and re-enable microphone control.",
                    "ed extensions enable micMute")
            ],
            verification: [
                instruction(
                    "config", "Inspect configuration",
                    "Confirm the extension and menu bar preferences.",
                    "ed config ls --group micmute --json")
            ]),
        descriptor(
            "lidAwake", "Keep a Mac running safely when the lid is closed and power is unplugged.",
            workflows: [
                instruction(
                    "session", "Start a lid session",
                    "Prevent lid-close sleep for a bounded or open-ended session."),
                instruction(
                    "battery", "Protect the battery",
                    "Pause automatically below a chosen charge level."),
            ],
            prerequisites: [
                instruction(
                    "helper", "Install the helper",
                    "Allow Edith to manage the system sleep assertion.",
                    "ed lid-awake status --json")
            ],
            examples: ["ed extensions enable lidAwake", "ed lid-awake on --for 1h"],
            docs: [documentation("guide", "Lid Awake guide", "docs/cli/lid-awake/README.md")],
            recovery: [
                instruction(
                    "off", "Restore normal sleep", "End the active session before retrying.",
                    "ed lid-awake off")
            ],
            verification: [
                instruction(
                    "status", "Check the assertion", "Confirm the helper and session state.",
                    "ed lid-awake status --json")
            ]),
        descriptor(
            "music", "Play and organize a local music library with system media controls.",
            workflows: [
                instruction(
                    "listen", "Play local music",
                    "Browse albums, artists and folders, then control playback."),
                instruction(
                    "download", "Add music", "Queue supported URLs for download into the library."),
            ],
            prerequisites: [
                instruction(
                    "library", "Choose a music library",
                    "Add supported audio files to Edith's music folder.",
                    "ed music library ~/Music"),
                instruction(
                    "download", "Install yt-dlp", "Install yt-dlp before using URL downloads.",
                    "ed tools install yt-dlp"),
            ],
            examples: ["ed extensions enable music", "ed music ls --json"],
            docs: [documentation("guide", "Music guide", "docs/cli/music/README.md")],
            recovery: [
                instruction(
                    "library", "Choose another library",
                    "Select an existing folder before rescanning.",
                    "ed music library ~/Music"),
                instruction(
                    "rescan", "Rescan the library", "Rebuild the library view after files change.",
                    "ed music rescan"),
            ],
            verification: [
                instruction(
                    "players", "Check playback", "Confirm Edith sees the player and library.",
                    "ed music players --json")
            ]),
        descriptor(
            "calendar", "See upcoming events beside the work they shape.",
            workflows: [
                instruction(
                    "schedule", "Review the schedule", "See upcoming events in the panel and app."),
                instruction(
                    "present", "Protect event details",
                    "Let Presenter blur calendar information while sharing."),
            ],
            prerequisites: [
                instruction(
                    "permission", "Grant Calendar access",
                    "Allow Edith to read events from macOS Calendar.",
                    "ed permissions request calendar")
            ],
            examples: ["ed extensions enable calendar", "ed calendar ls --json"],
            docs: [documentation("guide", "Calendar guide", "docs/cli/calendar/README.md")],
            recovery: [
                instruction(
                    "permission", "Refresh Calendar access",
                    "Request and refresh the mirrored permission state.", "ed permissions refresh")
            ],
            verification: [
                instruction(
                    "events", "List events", "Confirm upcoming events can be read.",
                    "ed calendar ls --json")
            ]),
        descriptor(
            "notchShelf", "Park files and glance at media, camera and alerts around the notch.",
            workflows: [
                instruction(
                    "files", "Stage files",
                    "Drop files on the shelf and drag them into another app later."),
                instruction(
                    "media", "Use the notch",
                    "Show now playing, camera and device alerts in one surface."),
            ],
            prerequisites: [
                instruction(
                    "display", "Use a supported display",
                    "Notch presentation depends on the current display layout."),
                instruction(
                    "optional", "Grant optional access",
                    "Application Audio, Camera, Bluetooth and Automation enable extra modules."),
            ],
            examples: ["ed extensions enable notchShelf", "ed shelf ls --json"],
            docs: [documentation("guide", "Shelf guide", "docs/cli/shelf/README.md")],
            recovery: [
                instruction(
                    "clear", "Clear stale shelf items", "Remove all parked items and retry.",
                    "ed shelf clear --yes --json")
            ],
            verification: [
                instruction(
                    "list", "List shelf items", "Confirm the shelf repository responds.",
                    "ed shelf ls --json")
            ]),
        descriptor(
            "clipboard", "Recover copied text, images and files and paste them again instantly.",
            workflows: [
                instruction(
                    "history", "Search clipboard history",
                    "Find recent copied content and pinned items."),
                instruction(
                    "paste", "Paste quickly", "Use the popup and optional global paste support."),
            ],
            prerequisites: [
                instruction(
                    "access", "Grant optional Accessibility",
                    "Accessibility enables instant paste into other apps.",
                    "ed permissions request accessibility")
            ],
            examples: ["ed extensions enable clipboard", "ed clipboard ls --json"],
            docs: [documentation("guide", "Clipboard guide", "docs/cli/clipboard/README.md")],
            recovery: [
                instruction(
                    "doctor", "Inspect storage", "Check clipboard settings and saved entries.",
                    "ed clipboard stats --json")
            ],
            verification: [
                instruction(
                    "list", "List recent copies", "Confirm clipboard history can be read.",
                    "ed clipboard ls --json")
            ]),
        descriptor(
            "keystrokeHighlight",
            "Show keyboard input as clear keycaps that disappear automatically.",
            workflows: [
                instruction(
                    "demo", "Record a demo",
                    "Show letters, symbols, navigation keys and shortcuts as they are pressed."),
                instruction(
                    "position", "Place the overlay",
                    "Keep the keycaps at the top or bottom of the screen under the pointer."),
                instruction(
                    "toggle", "Pause between takes",
                    "Start or pause the overlay without removing the extension.",
                    "ed config set keystrokeHighlightActive false"),
            ],
            prerequisites: [
                instruction(
                    "permission", "Grant Input Monitoring",
                    "Allow Edith to observe physical key presses outside its own windows.",
                    "ed permissions request inputMonitoring")
            ],
            examples: [
                "ed extensions enable keystrokeHighlight",
                "ed config set keystrokeHighlightActive true",
                "ed config set keystrokeHighlightDuration 1.5",
            ],
            docs: [
                documentation(
                    "guide", "Keystroke Highlight guide",
                    "docs/cli/keystroke-highlight/README.md")
            ],
            recovery: [
                instruction(
                    "doctor", "Check the overlay",
                    "Inspect the helper, permission and runtime state.",
                    "ed extensions doctor keystrokeHighlight --json")
            ],
            verification: [
                instruction(
                    "status", "Verify monitoring",
                    "Confirm the event monitor and overlay are ready.",
                    "ed extensions verify keystrokeHighlight --json")
            ]),
        descriptor(
            "focusDim", "Reduce visual noise by dimming everything behind the active app.",
            workflows: [
                instruction(
                    "focus", "Enter focus mode",
                    "Dim inactive windows and displays while keeping the front app clear."),
                instruction(
                    "tune", "Tune the effect",
                    "Adjust intensity, animation and other-display behavior."),
            ],
            prerequisites: [
                instruction(
                    "permission", "Grant Screen Recording",
                    "macOS requires Screen Recording to identify and dim windows.",
                    "ed permissions request screenRecording")
            ],
            examples: ["ed extensions enable focusDim", "ed config ls --group focusdim --json"],
            docs: [
                documentation("extensions", "Extensions guide", "docs/cli/extensions/README.md")
            ],
            recovery: [
                instruction(
                    "permission", "Refresh Screen Recording",
                    "Refresh the mirrored grant after changing System Settings.",
                    "ed permissions refresh")
            ],
            verification: [
                instruction(
                    "config", "Inspect dimming settings",
                    "Confirm the effect is enabled and configured.",
                    "ed config ls --group focusdim --json")
            ]),
        descriptor(
            "presenter",
            "Hide sensitive numbers automatically while sharing or recording your screen.",
            workflows: [
                instruction(
                    "protect", "Protect shared screens",
                    "Blur selected calendar, music, money and usage values."),
                instruction(
                    "detect", "React automatically",
                    "Enable protection when recording, sharing or mirroring is detected."),
            ],
            prerequisites: [
                instruction(
                    "permission", "Grant Screen Recording",
                    "Screen Recording lets Edith detect sharing and apply protection.",
                    "ed permissions request screenRecording")
            ],
            examples: ["ed extensions enable presenter", "ed config ls --group presenter --json"],
            docs: [
                documentation("extensions", "Extensions guide", "docs/cli/extensions/README.md")
            ],
            recovery: [
                instruction(
                    "permission", "Refresh sharing access",
                    "Refresh the mirrored Screen Recording grant.", "ed permissions refresh")
            ],
            verification: [
                instruction(
                    "config", "Inspect protection",
                    "Confirm automatic detection and blur categories.",
                    "ed config ls --group presenter --json")
            ]),
        descriptor(
            "emoji", "Insert any emoji macOS can draw into whatever you are typing in.",
            workflows: [
                instruction(
                    "pick", "Open the picker",
                    "Open the emoji panel from its shortcut or the command line.",
                    "ed emoji pick"),
                instruction(
                    "search", "Find an emoji",
                    "Type a name, keyword or shortcode to filter every category."),
                instruction(
                    "tone", "Choose a skin tone",
                    "Set the default tone applied to emoji that support one.",
                    "ed emoji tone medium"),
            ],
            prerequisites: [
                instruction(
                    "permission", "Grant Accessibility",
                    "macOS requires Accessibility to type into the frontmost app.",
                    "ed permissions request accessibility")
            ],
            examples: [
                "ed extensions enable emoji", "ed emoji ls --json",
                "ed emoji insert 1F600",
            ],
            docs: [documentation("guide", "Emoji Picker guide", "docs/cli/emoji/README.md")],
            recovery: [
                instruction(
                    "permission", "Refresh typing access",
                    "Refresh the mirrored Accessibility grant.", "ed permissions refresh")
            ],
            verification: [
                instruction(
                    "catalog", "Read the emoji catalog",
                    "Confirm the bundled catalog loads on this Mac.", "ed emoji ls --json")
            ]),
        descriptor(
            "colorPicker", "Sample an exact screen color and copy it in the format you need.",
            workflows: [
                instruction(
                    "sample", "Pick a color",
                    "Open the system loupe from Edith, its shortcut or the command line.",
                    "ed color pick"),
                instruction(
                    "reuse", "Reuse recent colors",
                    "Copy a previous sample in HEX, RGB or another format."),
            ],
            prerequisites: [
                instruction(
                    "permission", "Grant Screen Recording",
                    "macOS requires Screen Recording to sample pixels.",
                    "ed permissions request screenRecording")
            ],
            examples: [
                "ed extensions enable colorPicker", "ed color pick --json",
                "ed color ls --json",
            ],
            docs: [documentation("guide", "Color Picker guide", "docs/cli/color/README.md")],
            recovery: [
                instruction(
                    "permission", "Refresh sampling access",
                    "Refresh the mirrored Screen Recording grant.", "ed permissions refresh")
            ],
            verification: [
                instruction(
                    "history", "Read sampled colors",
                    "Confirm the color history repository responds.", "ed color ls --json")
            ]),
        descriptor(
            "homebrew", "Install, upgrade and remove Homebrew packages from one client.",
            workflows: [
                instruction(
                    "browse", "Browse packages",
                    "Search installed and discoverable formulae, casks and taps."),
                instruction(
                    "change", "Install or upgrade",
                    "Queue package changes and watch each one run to completion."),
            ],
            prerequisites: [
                instruction(
                    "tool", "Install Homebrew", "Put brew on Edith's PATH.",
                    "ed tools install homebrew")
            ],
            examples: ["ed extensions enable homebrew", "ed brew ls --json"],
            docs: [documentation("guide", "Homebrew guide", "docs/cli/brew/README.md")],
            recovery: [
                instruction(
                    "install", "Repair Homebrew", "Reinstall the managed Homebrew client.",
                    "ed tools install homebrew")
            ],
            verification: [
                instruction(
                    "list", "List packages", "Confirm brew reports installed packages.",
                    "ed brew ls --json")
            ]),
        descriptor(
            "cleaner", "Find reclaimable space on your drives and remove it after review.",
            workflows: [
                instruction(
                    "scan", "Scan for space", "Measure caches, logs and other reclaimable files."),
                instruction(
                    "clean", "Reclaim space", "Review each category before anything is removed."),
            ],
            prerequisites: [
                instruction(
                    "drives", "Choose drives", "Pick the volumes the cleaner is allowed to scan.",
                    "ed cleaner drives --json")
            ],
            examples: ["ed extensions enable cleaner", "ed cleaner scan --json"],
            docs: [documentation("guide", "Cleaner guide", "docs/cli/cleaner/README.md")],
            recovery: [
                instruction(
                    "drives", "Reset the drive selection",
                    "List the volumes the cleaner can reach.", "ed cleaner drives --json")
            ],
            verification: [
                instruction(
                    "scan", "Read a scan", "Confirm a scan reports category sizes.",
                    "ed cleaner scan --json")
            ]),
        descriptor(
            "downloads", "Queue audio and video downloads that outlive the window.",
            workflows: [
                instruction("add", "Queue a download", "Add one or more URLs to the queue."),
                instruction(
                    "watch", "Follow progress", "Track each item until the file lands on disk."),
            ],
            prerequisites: [
                instruction(
                    "tool", "Install yt-dlp", "Put yt-dlp on Edith's PATH.",
                    "ed tools install yt-dlp"),
                instruction(
                    "folder", "Choose a music folder",
                    "Downloads are written into the folder Music uses."),
            ],
            examples: ["ed extensions enable downloads", "ed download ls --json"],
            docs: [documentation("guide", "Download guide", "docs/cli/download/README.md")],
            recovery: [
                instruction(
                    "tool", "Repair yt-dlp", "Reinstall the managed downloader.",
                    "ed download tool --json"),
                instruction(
                    "retry", "Retry a failed item", "Requeue an item that stopped early.",
                    "ed download retry"),
            ],
            verification: [
                instruction(
                    "queue", "Read the queue", "Confirm the queue is readable.",
                    "ed download ls --json")
            ]),
        descriptor(
            "audioMixer", "Set the volume of each app from the notch shelf.",
            workflows: [
                instruction("mix", "Balance apps", "Change one app's volume without the others."),
                instruction("mute", "Silence an app", "Mute a single app while the rest play on."),
            ],
            prerequisites: [
                instruction(
                    "shelf", "Enable Notch Shelf", "The mixer lives in the shelf's audio tab.",
                    "ed extensions enable notchShelf"),
                instruction(
                    "permission", "Allow application audio",
                    "macOS asks for audio capture the first time the mixer runs."),
            ],
            examples: ["ed extensions enable audioMixer", "ed shelf ls --json"],
            docs: [documentation("guide", "Notch Shelf guide", "docs/cli/shelf/README.md")],
            recovery: [
                instruction(
                    "shelf", "Check the shelf", "Confirm the shelf is enabled and reachable.",
                    "ed extensions doctor notchShelf --json")
            ],
            verification: [
                instruction(
                    "shelf", "Read the shelf", "Confirm the shelf responds.", "ed shelf ls --json")
            ]),
    ]

    public static let byID = Dictionary(
        uniqueKeysWithValues: allDescriptors.map { ($0.id, $0) })

    public static func descriptor(for extensionID: String) -> ExtensionLifecycleDescriptor? {
        byID[extensionID]
    }

    private static func descriptor(
        _ id: String, _ value: String, workflows: [ExtensionLifecycleInstruction],
        prerequisites: [ExtensionLifecycleInstruction], examples: [String],
        docs: [ExtensionDocumentationLink], recovery: [ExtensionLifecycleInstruction],
        verification: [ExtensionLifecycleInstruction]
    ) -> ExtensionLifecycleDescriptor {
        ExtensionLifecycleDescriptor(
            id: id, value: value, workflows: workflows, prerequisites: prerequisites,
            cliExamples: examples, documentation: docs, recovery: recovery,
            verification: verification)
    }

    private static func instruction(
        _ id: String, _ title: String, _ detail: String, _ command: String? = nil
    ) -> ExtensionLifecycleInstruction {
        ExtensionLifecycleInstruction(id: id, title: title, detail: detail, command: command)
    }

    private static func documentation(
        _ id: String, _ title: String, _ path: String
    ) -> ExtensionDocumentationLink {
        ExtensionDocumentationLink(id: id, title: title, path: path)
    }
}

public extension ExtensionRegistryEntry {
    var lifecycle: ExtensionLifecycleDescriptor? {
        ExtensionLifecycleCatalog.descriptor(for: id)
    }
}
