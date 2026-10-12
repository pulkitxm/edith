import Foundation

public struct HostExtensionRequirement: Equatable, Sendable {
    public enum ToolRule: String, Sendable { case all, any }
    public struct Original: Equatable, Sendable {
        public let requiredTools: [String]
        public let optionalTools: [String]
        public let requiredPermissions: [String]
        public let optionalPermissions: [String]
        public let requiredCapabilities: [String]
        public let optionalCapabilities: [String]
        public let toolRule: ToolRule
        public let requiresHelper: Bool
    }
    public let id: String
    public let title: String
    public let original: Original?
    public let dependencies: [String]
    public let setupInstruction: String
}

public enum HostExtensionRequirementCatalog {
    public static let originalRevision = "91d0e13de56aaf297ad4630d2c36ef124da5bf0c"
    public static let entries: [HostExtensionRequirement] = [
        .init(
            id: "keepAwake", title: "Keep Awake",
            original: .init(
                requiredTools: [], optionalTools: [], requiredPermissions: [],
                optionalPermissions: [], requiredCapabilities: ["preventSleep"],
                optionalCapabilities: [], toolRule: .all, requiresHelper: true), dependencies: [],
            setupInstruction: "Keep Awake is ready to prevent idle sleep without System."),
        .init(
            id: "audioMixer", title: "Audio Mixer",
            original: .init(
                requiredTools: [], optionalTools: [], requiredPermissions: [],
                optionalPermissions: ["applicationAudio"],
                requiredCapabilities: ["applicationAudio"], optionalCapabilities: [],
                toolRule: .all, requiresHelper: true), dependencies: ["notchShelf"],
            setupInstruction: "Turn on Notch Shelf to reach the mixer."),
        .init(
            id: "focusDim", title: "Focus Dim",
            original: .init(
                requiredTools: [], optionalTools: [], requiredPermissions: ["screenRecording"],
                optionalPermissions: [], requiredCapabilities: ["windowDimming"],
                optionalCapabilities: [], toolRule: .all, requiresHelper: true), dependencies: [],
            setupInstruction:
                "A stored dim intensity, animation duration, or display mode is invalid."),
        .init(
            id: "windowSweaters", title: "Window Sweaters",
            original: .init(
                requiredTools: [], optionalTools: [], requiredPermissions: [],
                optionalPermissions: ["accessibility"], requiredCapabilities: ["windowDecoration"],
                optionalCapabilities: [], toolRule: .all, requiresHelper: true), dependencies: [],
            setupInstruction: "A stored border width, stitch size, colourway or pattern is invalid."
        ),
        .init(
            id: "micMute", title: "Mic Mute",
            original: .init(
                requiredTools: [], optionalTools: [], requiredPermissions: [],
                optionalPermissions: [], requiredCapabilities: ["microphoneControl"],
                optionalCapabilities: ["globalShortcuts"], toolRule: .all, requiresHelper: true),
            dependencies: [], setupInstruction: "No microphone input device is available."),
        .init(
            id: "keystrokeHighlight", title: "Keystroke Highlight",
            original: .init(
                requiredTools: [], optionalTools: [], requiredPermissions: ["inputMonitoring"],
                optionalPermissions: [], requiredCapabilities: ["keystrokeObservation"],
                optionalCapabilities: [], toolRule: .all, requiresHelper: true), dependencies: [],
            setupInstruction: "Keystroke Highlight is off."),
        .init(
            id: "presenter", title: "Presenter",
            original: .init(
                requiredTools: [], optionalTools: [], requiredPermissions: ["screenRecording"],
                optionalPermissions: [], requiredCapabilities: ["screenShareDetection"],
                optionalCapabilities: [], toolRule: .all, requiresHelper: true), dependencies: [],
            setupInstruction: "Presenter has no protected data categories enabled."),
        .init(
            id: "colorPicker", title: "Color Picker",
            original: .init(
                requiredTools: [], optionalTools: [], requiredPermissions: ["screenRecording"],
                optionalPermissions: [], requiredCapabilities: ["screenColorSampling"],
                optionalCapabilities: ["globalShortcuts"], toolRule: .all, requiresHelper: true),
            dependencies: [],
            setupInstruction: "The stored color format, profile, or history size is invalid."),
        .init(
            id: "systemStats", title: "CPU & Memory in menu bar",
            original: .init(
                requiredTools: [], optionalTools: [], requiredPermissions: [],
                optionalPermissions: [], requiredCapabilities: ["systemMetrics"],
                optionalCapabilities: [], toolRule: .all, requiresHelper: true), dependencies: [],
            setupInstruction: "CPU metrics could not be sampled."),
        .init(
            id: "emoji", title: "Emoji Picker",
            original: .init(
                requiredTools: [], optionalTools: [], requiredPermissions: [],
                optionalPermissions: ["accessibility"], requiredCapabilities: ["emojiInsertion"],
                optionalCapabilities: ["globalShortcuts"], toolRule: .all, requiresHelper: true),
            dependencies: [],
            setupInstruction: "The stored skin tone or frequently used count is invalid."),
        .init(
            id: "homebrew", title: "Packages",
            original: .init(
                requiredTools: ["homebrew"], optionalTools: [], requiredPermissions: [],
                optionalPermissions: [], requiredCapabilities: ["packageManagement"],
                optionalCapabilities: [], toolRule: .all, requiresHelper: false),
            dependencies: ["appMaintenance"],
            setupInstruction: "Homebrew is not installed on this Mac."),
        .init(
            id: "calendar", title: "Calendar",
            original: .init(
                requiredTools: [], optionalTools: [], requiredPermissions: ["calendar"],
                optionalPermissions: [], requiredCapabilities: ["calendarEvents"],
                optionalCapabilities: [], toolRule: .all, requiresHelper: true), dependencies: [],
            setupInstruction: "Calendar access has not been requested."),
        .init(
            id: "jev", title: "Jev", original: nil, dependencies: [],
            setupInstruction:
                "No original registry entry. A pure inspection from the extracted feature owner is required."
        ),
        .init(
            id: "system", title: "System",
            original: .init(
                requiredTools: [], optionalTools: [], requiredPermissions: [],
                optionalPermissions: ["accessibility", "inputMonitoring"],
                requiredCapabilities: ["runningApplications"],
                optionalCapabilities: ["inputSuppression"], toolRule: .all, requiresHelper: true),
            dependencies: [],
            setupInstruction: "No regular applications are visible to the system runtime."),
        .init(
            id: "timeLapse", title: "Screen Recorder",
            original: .init(
                requiredTools: [], optionalTools: [], requiredPermissions: ["screenRecording"],
                optionalPermissions: [], requiredCapabilities: ["screenTimeLapse"],
                optionalCapabilities: [], toolRule: .all, requiresHelper: false), dependencies: [],
            setupInstruction:
                "Choose displays or windows in Screen Recorder, then select Standard or Time-lapse mode."
        ),
        .init(
            id: "cleaner", title: "Cleaner",
            original: .init(
                requiredTools: [], optionalTools: [], requiredPermissions: [],
                optionalPermissions: [], requiredCapabilities: ["diskCleaning"],
                optionalCapabilities: [], toolRule: .all, requiresHelper: false), dependencies: [],
            setupInstruction: "No volume is readable for scanning."),
        .init(
            id: "appMaintenance", title: "Updates",
            original: .init(
                requiredTools: [], optionalTools: ["homebrew"], requiredPermissions: [],
                optionalPermissions: ["notifications"],
                requiredCapabilities: ["runningApplications"],
                optionalCapabilities: ["packageManagement"], toolRule: .all, requiresHelper: false),
            dependencies: [], setupInstruction: "No readable Applications folder is available."),
        .init(
            id: "blitztree", title: "BlitzTree",
            original: .init(
                requiredTools: [], optionalTools: [], requiredPermissions: [],
                optionalPermissions: ["fullDisk"], requiredCapabilities: ["diskCleaning"],
                optionalCapabilities: [], toolRule: .all, requiresHelper: false), dependencies: [],
            setupInstruction: "The built-in disk scanner is ready. Choose a folder in BlitzTree."),
        .init(
            id: "plugins", title: "Plugins",
            original: .init(
                requiredTools: [], optionalTools: [], requiredPermissions: [],
                optionalPermissions: [], requiredCapabilities: ["skillInstallation"],
                optionalCapabilities: [], toolRule: .all, requiresHelper: false), dependencies: [],
            setupInstruction:
                "Install Node.js 22.20 or later to install plugins. Browsing is available now."),
        .init(
            id: "notchShelf", title: "Notch Shelf",
            original: .init(
                requiredTools: [], optionalTools: [], requiredPermissions: [],
                optionalPermissions: ["bluetooth", "camera", "automation"],
                requiredCapabilities: ["fileShelf"],
                optionalCapabilities: [
                    "bluetoothMonitoring", "cameraPreview", "externalMediaControl", "webBrowsing",
                ], toolRule: .all, requiresHelper: true), dependencies: [],
            setupInstruction: "The shelf index could not be read."),
        .init(
            id: "clipboard", title: "Clipboard",
            original: .init(
                requiredTools: [], optionalTools: [], requiredPermissions: [],
                optionalPermissions: ["accessibility"], requiredCapabilities: ["clipboardHistory"],
                optionalCapabilities: ["globalPaste", "globalShortcuts"], toolRule: .all,
                requiresHelper: true), dependencies: [],
            setupInstruction: "Clipboard history is ready and empty."),
        .init(
            id: "music", title: "Music",
            original: .init(
                requiredTools: [], optionalTools: [], requiredPermissions: [],
                optionalPermissions: [], requiredCapabilities: ["localMusicPlayback"],
                optionalCapabilities: ["mediaControls"], toolRule: .all, requiresHelper: true),
            dependencies: [],
            setupInstruction: "The configured music library folder does not exist."),
        .init(
            id: "docs", title: "Documents", original: nil, dependencies: [],
            setupInstruction:
                "No original registry entry. A pure inspection from the extracted feature owner is required."
        ),
        .init(
            id: "latex", title: "LaTeX",
            original: .init(
                requiredTools: [],
                optionalTools: ["tectonic", "latexmk", "gh", "quinjet", "pukbot"],
                requiredPermissions: [], optionalPermissions: [],
                requiredCapabilities: ["localMediaEditing"], optionalCapabilities: [],
                toolRule: .all, requiresHelper: false), dependencies: [],
            setupInstruction: "Add a local source or GitHub repository in the LaTeX window."),
        .init(
            id: "companion", title: "Memory",
            original: .init(
                requiredTools: [], optionalTools: [], requiredPermissions: [],
                optionalPermissions: [], requiredCapabilities: ["companionService"],
                optionalCapabilities: [], toolRule: .all, requiresHelper: false), dependencies: [],
            setupInstruction:
                "Companion is not configured. Choose a host and deploy it, or save another endpoint."
        ),
        .init(
            id: "terminal", title: "Terminal", original: nil, dependencies: [],
            setupInstruction:
                "No original registry entry. A pure inspection from the extracted feature owner is required."
        ),
        .init(
            id: "studio", title: "Studio",
            original: .init(
                requiredTools: [], optionalTools: ["ffmpeg", "qpdf"], requiredPermissions: [],
                optionalPermissions: [], requiredCapabilities: ["localMediaEditing"],
                optionalCapabilities: [], toolRule: .all, requiresHelper: false), dependencies: [],
            setupInstruction: "Drop files into Studio in the Edith window to edit or convert them."),
        .init(
            id: "usage", title: "Usage",
            original: .init(
                requiredTools: ["claude", "codex"], optionalTools: [], requiredPermissions: [],
                optionalPermissions: ["notifications"], requiredCapabilities: ["usageCollection"],
                optionalCapabilities: ["notifications"], toolRule: .any, requiresHelper: true),
            dependencies: [], setupInstruction: "The bundled usage collector is missing."),
        .init(
            id: "bifrost", title: "Bifrost",
            original: .init(
                requiredTools: [], optionalTools: [], requiredPermissions: [],
                optionalPermissions: ["accessibility"],
                requiredCapabilities: ["applicationLaunching"],
                optionalCapabilities: ["globalShortcuts", "globalPaste"], toolRule: .all,
                requiresHelper: true), dependencies: [],
            setupInstruction: "No applications are indexed yet; the first search builds the index."),
        .init(
            id: "lidAwake", title: "Lid Awake",
            original: .init(
                requiredTools: [], optionalTools: [], requiredPermissions: [],
                optionalPermissions: [], requiredCapabilities: ["preventSleep"],
                optionalCapabilities: [], toolRule: .all, requiresHelper: true), dependencies: [],
            setupInstruction:
                "The sleep helper needs approval in System Settings > General > Login Items."),
        .init(
            id: "attention", title: "Attention",
            original: .init(
                requiredTools: [], optionalTools: [], requiredPermissions: [],
                optionalPermissions: [], requiredCapabilities: ["runningApplications"],
                optionalCapabilities: [], toolRule: .all, requiresHelper: true), dependencies: [],
            setupInstruction: "Turn on application tracking, browser tracking, or both."),
        .init(
            id: "machines", title: "Machines", original: nil, dependencies: [],
            setupInstruction:
                "No original registry entry. A pure inspection from the extracted feature owner is required."
        ),
        .init(
            id: "downloads", title: "Downloads",
            original: .init(
                requiredTools: ["yt-dlp", "ffmpeg", "deno"], optionalTools: ["gallery-dl"],
                requiredPermissions: [], optionalPermissions: [],
                requiredCapabilities: ["mediaDownloads"], optionalCapabilities: [], toolRule: .all,
                requiresHelper: false), dependencies: [],
            setupInstruction: "Choose an existing, writable download folder."),
        .init(
            id: "seoAudit", title: "Site Audit",
            original: .init(
                requiredTools: [], optionalTools: [], requiredPermissions: [],
                optionalPermissions: [], requiredCapabilities: ["siteAuditing"],
                optionalCapabilities: [], toolRule: .all, requiresHelper: false), dependencies: [],
            setupInstruction: "Site Audit is ready to store projects and run history locally."),
        .init(
            id: "virtualCamera", title: "Virtual Camera",
            original: .init(
                requiredTools: [], optionalTools: [], requiredPermissions: ["camera"],
                optionalPermissions: [], requiredCapabilities: ["virtualCamera"],
                optionalCapabilities: [], toolRule: .all, requiresHelper: true), dependencies: [],
            setupInstruction: "Install the Edith Camera extension from the Virtual Camera page."),
        .init(
            id: "codeStats", title: "Code Stats",
            original: .init(
                requiredTools: ["git"], optionalTools: ["gh"], requiredPermissions: [],
                optionalPermissions: [], requiredCapabilities: ["codeStatistics"],
                optionalCapabilities: [], toolRule: .all, requiresHelper: false), dependencies: [],
            setupInstruction: "Install Git to mirror and analyse your repositories."),
        .init(
            id: "herdr", title: "Sessions",
            original: .init(
                requiredTools: [], optionalTools: [], requiredPermissions: [],
                optionalPermissions: [], requiredCapabilities: ["herdrSessions"],
                optionalCapabilities: [], toolRule: .all, requiresHelper: false), dependencies: [],
            setupInstruction: "Herdr is not installed on this Mac or a configured machine."),
        .init(
            id: "quinjet", title: "Review",
            original: .init(
                requiredTools: ["quinjet"], optionalTools: [], requiredPermissions: [],
                optionalPermissions: [], requiredCapabilities: ["localTerminal"],
                optionalCapabilities: [], toolRule: .all, requiresHelper: false),
            dependencies: ["herdr"], setupInstruction: "The Quinjet executable is not installed."),
        .init(
            id: "database", title: "Database",
            original: .init(
                requiredTools: [], optionalTools: [], requiredPermissions: [],
                optionalPermissions: [], requiredCapabilities: ["databaseBroker"],
                optionalCapabilities: [], toolRule: .all, requiresHelper: false), dependencies: [],
            setupInstruction:
                "No original registry entry. A pure inspection from the extracted feature owner is required."
        ),
    ]

    public static func entry(id: String) throws -> HostExtensionRequirement {
        guard let entry = entries.first(where: { $0.id == id }) else {
            throw HostCLIError.usage("Unknown extension requirement ID: " + id)
        }
        return entry
    }
}
