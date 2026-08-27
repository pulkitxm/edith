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
    public static let descriptors: [ExtensionLifecycleDescriptor] = [
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
            "systemStats", "Monitor system pressure and throughput without opening a window.",
            workflows: [
                instruction(
                    "glance", "Monitor the Mac",
                    "Watch CPU and memory in the menu bar, with full metrics one click away."),
                instruction(
                    "alerts", "Catch sustained pressure",
                    "Notify after CPU, memory, storage, or battery pressure persists."),
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
                    "sample", "Sample metrics",
                    "Confirm every available metric family can be read.",
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
            "windowTools", "Arrange the active window quickly while staying in the current Space.",
            workflows: [
                instruction(
                    "arrange", "Arrange a window",
                    "Use a shortcut, settings control, or command to place the active window."),
                instruction(
                    "maximize", "Maximize without a Space",
                    "Make the green button fill the usable display and click it again to restore."),
            ],
            prerequisites: [
                instruction(
                    "permission", "Grant Accessibility",
                    "Accessibility lets Edith read and move the active window.",
                    "ed permissions request accessibility")
            ],
            examples: [
                "ed extensions enable windowTools", "ed window left-half --json",
                "ed window restore",
            ],
            docs: [
                documentation("guide", "Window Tools guide", "docs/cli/window/README.md")
            ],
            recovery: [
                instruction(
                    "permission", "Refresh Accessibility",
                    "Refresh the mirrored grant after changing System Settings.",
                    "ed permissions refresh")
            ],
            verification: [
                instruction(
                    "config", "Inspect Window Tools settings",
                    "Confirm the extension, green button, and shortcuts are configured.",
                    "ed config ls --group windowtools --json")
            ]),
    ]

    public static let byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })

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
