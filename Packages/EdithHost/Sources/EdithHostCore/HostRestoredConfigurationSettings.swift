import Foundation

enum HostRestoredConfigurationSettings {
    static let all: [HostCLISetting] = [
        .init(
            "agentActivityProviders", .string, group: "agent",
            summary: "Provider observation and explicit approval controls for agent surfaces.",
            fallback: .string(
                "{\"monitorTerminalAttention\":false,\"providers\":{},\"quietMinutes\":10}")),
        .init(
            "agentNotifyOnErrors", .bool, group: "agent",
            summary: "Notify when a coding agent stops with an error.",
            fallback: .bool(true)),
        .init(
            "agentNotifyWhenBlocked", .bool, group: "agent",
            summary: "Notify when a coding agent needs approval or an answer.",
            fallback: .bool(true)),
        .init(
            "agentNotifyWhenFinished", .bool, group: "agent",
            summary: "Notify when a coding agent finishes its work.",
            fallback: .bool(true)),
        .init(
            "agentNotifyWhenStuck", .bool, group: "agent",
            summary: "Notify when a coding agent shows no progress on screen.",
            fallback: .bool(false)),
        .init(
            "agentOpenDiffWhenFinished", .bool, group: "agent",
            summary: "Open the diff when a coding agent finishes with changes to review.",
            fallback: .bool(false)),
        .init(
            "agentRegistrationState", .string, group: "agent",
            summary: "Login Items registration state of the background agent.",
            allowed: ["notRegistered", "enabled", "awaitingApproval", "notFound"],
            fallback: .string("notRegistered"),
            readOnly: true),
        .init(
            "agentStuckMinutes", .int, group: "agent",
            summary: "Minutes without screen progress before an agent counts as stuck.",
            minimum: 2,
            maximum: 120,
            fallback: .integer(10)),
        .init(
            "appMaintenanceCategoriesExpanded", .bool, group: "panel",
            summary: "Whether App Maintenance sections are expanded in the main sidebar.",
            fallback: .bool(true),
            owner: "appMaintenance"),
        .init(
            "backupLimits", .bool, group: "backup",
            summary: "Back up limit history to iCloud."),
        .init(
            "backupUsage", .bool, group: "backup",
            summary: "Back up usage history to iCloud."),
        .init(
            "bifrostEnabled", .bool, group: "bifrost",
            summary: "Bifrost extension: one bar for applications, sums and conversions.",
            fallback: .bool(false),
            owner: "bifrost"),
        .init(
            "bifrostHotKeyCode", .int, group: "bifrost",
            summary: "Virtual key code of the launcher shortcut.",
            owner: "bifrost"),
        .init(
            "bifrostHotKeyLabel", .string, group: "bifrost",
            summary: "Printable label for the launcher shortcut.",
            owner: "bifrost"),
        .init(
            "bifrostHotKeyMods", .int, group: "bifrost",
            summary: "Carbon modifier mask of the launcher shortcut.",
            owner: "bifrost"),
        .init(
            "bifrostIndexedAt", .number, group: "bifrost",
            summary: "When the application index was last rebuilt.",
            readOnly: true,
            owner: "bifrost"),
        .init(
            "bifrostPasteSnippets", .bool, group: "bifrost",
            summary: "Paste a snippet straight into the app you were typing in.",
            fallback: .bool(true),
            owner: "bifrost"),
        .init(
            "bifrostPopupAt", .string, group: "bifrost",
            summary: "Where the launcher bar opens.",
            allowed: ["cursor", "statusItem", "window", "center", "lastPosition"],
            fallback: .string("center"),
            owner: "bifrost"),
        .init(
            "bifrostQuicklinks", .string, group: "bifrost",
            summary: "Saved quicklinks, stored as JSON.",
            owner: "bifrost"),
        .init(
            "bifrostResultLimit", .int, group: "bifrost",
            summary: "How many results the launcher shows at once.",
            minimum: 3,
            maximum: 12,
            fallback: .integer(8),
            owner: "bifrost"),
        .init(
            "bifrostShellCommands", .string, group: "bifrost",
            summary: "Saved shell commands, stored as JSON.",
            owner: "bifrost"),
        .init(
            "bifrostSnippets", .string, group: "bifrost",
            summary: "Saved snippets, stored as JSON.",
            owner: "bifrost"),
        .init(
            "bifrostSourceAppleShortcuts", .bool, group: "bifrost",
            summary: "Search the shortcuts you built in the Shortcuts app.",
            fallback: .bool(true),
            owner: "bifrost"),
        .init(
            "bifrostSourceOpenWindows", .bool, group: "bifrost",
            summary: "Offer every open window by title.",
            fallback: .bool(false),
            owner: "bifrost"),
        .init(
            "bifrostSourceQuicklinks", .bool, group: "bifrost",
            summary: "Search your saved quicklinks.",
            fallback: .bool(true),
            owner: "bifrost"),
        .init(
            "bifrostSourceRunningApplications", .bool, group: "bifrost",
            summary: "Offer the apps that are running right now.",
            fallback: .bool(true),
            owner: "bifrost"),
        .init(
            "bifrostSourceShellCommands", .bool, group: "bifrost",
            summary: "Search your saved shell commands.",
            fallback: .bool(true),
            owner: "bifrost"),
        .init(
            "bifrostSourceSnippets", .bool, group: "bifrost",
            summary: "Search your saved snippets.",
            fallback: .bool(true),
            owner: "bifrost"),
        .init(
            "bifrostSourceSystemActions", .bool, group: "bifrost",
            summary: "Offer lock, sleep, appearance and trash actions.",
            fallback: .bool(true),
            owner: "bifrost"),
        .init(
            "bifrostSourceWindowActions", .bool, group: "bifrost",
            summary: "Offer the window management actions.",
            fallback: .bool(true),
            owner: "bifrost"),
        .init(
            "clipboardAutoPaste", .bool, group: "clipboard",
            summary: "Paste straight into the frontmost app on pick.",
            fallback: .bool(true),
            owner: "clipboard"),
        .init(
            "clipboardBackup", .bool, group: "clipboard",
            summary: "Include clipboard history in the iCloud backup.",
            owner: "clipboard"),
        .init(
            "clipboardCapturePaused", .bool, group: "clipboard",
            summary: "Stop recording new copies until capture is resumed.",
            fallback: .bool(false),
            owner: "clipboard"),
        .init(
            "clipboardCheckInterval", .number, group: "clipboard",
            summary: "Seconds between pasteboard polls.",
            fallback: .number(1),
            owner: "clipboard"),
        .init(
            "clipboardEnabled", .bool, group: "clipboard",
            summary: "Clipboard extension: history with instant paste.",
            fallback: .bool(false),
            owner: "clipboard"),
        .init(
            "clipboardHotKeyCode", .int, group: "clipboard",
            summary: "Virtual key code of the clipboard panel shortcut.",
            owner: "clipboard"),
        .init(
            "clipboardHotKeyLabel", .string, group: "clipboard",
            summary: "Printable label for the clipboard panel shortcut.",
            owner: "clipboard"),
        .init(
            "clipboardHotKeyMods", .int, group: "clipboard",
            summary: "Carbon modifier mask of the clipboard panel shortcut.",
            owner: "clipboard"),
        .init(
            "clipboardIgnoredApps", .csv, group: "clipboard",
            summary: "Comma separated bundle identifiers never captured.",
            owner: "clipboard"),
        .init(
            "clipboardMaxAgeDays", .int, group: "clipboard",
            summary: "Days a clipboard entry is kept before it is pruned.",
            owner: "clipboard"),
        .init(
            "clipboardMaxItemBytes", .int, group: "clipboard",
            summary: "Largest single clipboard entry kept, in bytes.",
            owner: "clipboard"),
        .init(
            "clipboardMaxItems", .int, group: "clipboard",
            summary: "Maximum entries kept in the clipboard history.",
            owner: "clipboard"),
        .init(
            "clipboardPastePlainText", .bool, group: "clipboard",
            summary: "Strip formatting when pasting.",
            owner: "clipboard"),
        .init(
            "clipboardPinTo", .string, group: "clipboard",
            summary: "Which edge the clipboard panel grows from.",
            allowed: ["top", "bottom"],
            fallback: .string("top"),
            owner: "clipboard"),
        .init(
            "clipboardPopupAt", .string, group: "clipboard",
            summary: "Where the clipboard panel opens.",
            allowed: ["cursor", "statusItem", "window", "center", "lastPosition"],
            fallback: .string("cursor"),
            owner: "clipboard"),
        .init(
            "clipboardSaveFiles", .bool, group: "clipboard",
            summary: "Capture copied files.",
            owner: "clipboard"),
        .init(
            "clipboardSaveImages", .bool, group: "clipboard",
            summary: "Capture copied images.",
            owner: "clipboard"),
        .init(
            "clipboardSaveText", .bool, group: "clipboard",
            summary: "Capture copied text.",
            owner: "clipboard"),
        .init(
            "clipboardShowFooter", .bool, group: "clipboard",
            summary: "Show the hint footer in the clipboard panel.",
            owner: "clipboard"),
        .init(
            "clipboardWindowPositionX", .number, group: "clipboard",
            summary: "Last clipboard panel x position.",
            owner: "clipboard"),
        .init(
            "clipboardWindowPositionY", .number, group: "clipboard",
            summary: "Last clipboard panel y position.",
            owner: "clipboard"),
        .init(
            "codeStatsExcludedAccounts", .stringList, group: "codestats",
            summary: "gh account logins whose repositories are not synced or counted.",
            owner: "codeStats"),
        .init(
            "codeStatsFolderPath", .string, group: "codestats",
            summary: "Folder holding the repository mirror. Change it with ed code-stats folder.",
            readOnly: true,
            owner: "codeStats"),
        .init(
            "codeStatsIdentityEmails", .stringList, group: "codestats",
            summary: "Author emails that mark a commit as yours.",
            owner: "codeStats"),
        .init(
            "codeStatsIdentitySubstrings", .stringList, group: "codestats",
            summary: "Name or login fragments that mark a commit as yours.",
            owner: "codeStats"),
        .init(
            "codeStatsIncludeArchived", .bool, group: "codestats",
            summary: "Mirror and count archived repositories.",
            fallback: .bool(true),
            owner: "codeStats"),
        .init(
            "codeStatsIncludeForks", .bool, group: "codestats",
            summary: "Mirror and count repositories that are forks.",
            fallback: .bool(false),
            owner: "codeStats"),
        .init(
            "codeStatsScheduleHour", .int, group: "codestats",
            summary: "Hour of the day a scheduled refresh runs.",
            minimum: 0,
            maximum: 23,
            fallback: .integer(9),
            owner: "codeStats"),
        .init(
            "codeStatsScheduleKind", .string, group: "codestats",
            summary: "How often Code Stats refreshes on its own.",
            allowed: ["manual", "daily", "weekly"],
            fallback: .string("manual"),
            owner: "codeStats"),
        .init(
            "codeStatsScheduleWeekday", .int, group: "codestats",
            summary: "Weekday a weekly refresh runs, from 1 for Sunday to 7 for Saturday.",
            minimum: 1,
            maximum: 7,
            fallback: .integer(2),
            owner: "codeStats"),
        .init(
            "colorPickerCopyFormat", .string, group: "colorpicker",
            summary: "Format the sampled colour is copied in.",
            allowed: ["hex", "rgb", "hsl", "swiftUI", "nsColor"],
            fallback: .string("hex"),
            owner: "colorPicker"),
        .init(
            "colorPickerEnabled", .bool, group: "colorpicker",
            summary: "Color Picker extension: system loupe on a hotkey.",
            fallback: .bool(false),
            owner: "colorPicker"),
        .init(
            "colorPickerHistorySize", .int, group: "colorpicker",
            summary: "Number of swatches kept in the history.",
            owner: "colorPicker"),
        .init(
            "colorPickerHotKeyCode", .int, group: "colorpicker",
            summary: "Virtual key code of the colour picker shortcut.",
            owner: "colorPicker"),
        .init(
            "colorPickerHotKeyLabel", .string, group: "colorpicker",
            summary: "Printable label for the colour picker shortcut.",
            owner: "colorPicker"),
        .init(
            "colorPickerHotKeyMods", .int, group: "colorpicker",
            summary: "Carbon modifier mask of the colour picker shortcut.",
            owner: "colorPicker"),
        .init(
            "colorPickerProfile", .string, group: "colorpicker",
            summary: "Colour space the loupe samples in.",
            allowed: ["sRGB", "displayP3"],
            fallback: .string("sRGB"),
            owner: "colorPicker"),
        .init(
            "companionEndpoint", .string, group: "companion",
            summary: "Companion API base URL the app and CLI talk to.",
            fallback: .string("http://127.0.0.1:4820"),
            owner: "companion"),
        .init(
            "companionTab", .string, group: "companion",
            summary: "Companion screen shown on open.",
            allowed: ["chat", "capture", "desk", "library", "mind", "setup", "settings"],
            fallback: .string("chat"),
            owner: "companion"),
        .init(
            "completionsAutoRefresh", .bool, group: "terminal",
            summary: "Keep the shell completion scripts current when the app starts.",
            fallback: .bool(true),
            owner: "terminal"),
        .init(
            "downloadsEnabled", .bool, group: "music",
            summary: "Downloads ability: queued audio and video downloads.",
            fallback: .bool(false),
            owner: "music"),
        .init(
            "emojiEnabled", .bool, group: "emoji",
            summary: "Emoji Picker extension: every macOS emoji on a hotkey.",
            fallback: .bool(false),
            owner: "emoji"),
        .init(
            "emojiFrequentCount", .int, group: "emoji",
            summary: "How many frequently used emoji pin to the top of the picker.",
            minimum: 0,
            maximum: 24,
            fallback: .integer(10),
            owner: "emoji"),
        .init(
            "emojiHotKeyCode", .int, group: "emoji",
            summary: "Virtual key code of the emoji picker shortcut.",
            owner: "emoji"),
        .init(
            "emojiHotKeyLabel", .string, group: "emoji",
            summary: "Printable label for the emoji picker shortcut.",
            owner: "emoji"),
        .init(
            "emojiHotKeyMods", .int, group: "emoji",
            summary: "Carbon modifier mask of the emoji picker shortcut.",
            owner: "emoji"),
        .init(
            "emojiPopupAt", .string, group: "emoji",
            summary: "Where the emoji picker opens.",
            allowed: ["cursor", "statusItem", "window", "center", "lastPosition"],
            fallback: .string("cursor"),
            owner: "emoji"),
        .init(
            "emojiSkinTone", .int, group: "emoji",
            summary: "Default skin tone index applied to emoji that support one.",
            minimum: 0,
            maximum: 5,
            fallback: .integer(0),
            owner: "emoji"),
        .init(
            "herdrGhosttyTerminal", .bool, group: "herdr",
            summary: "Run Herdr terminals on the Ghostty engine instead of SwiftTerm.",
            fallback: .bool(true),
            owner: "herdr"),
        .init(
            "herdrLaunchDefaults", .map, group: "herdr",
            summary: "Model, effort and fast mode per agent kind when Edith starts an agent.",
            fallback: .object([:]),
            owner: "herdr"),
        .init(
            "herdrTerminalConfirmClose", .bool, group: "herdr",
            summary: "Ask before closing a terminal, or a tab, that is running something.",
            fallback: .bool(true),
            owner: "herdr"),
        .init(
            "herdrTerminalFontSize", .number, group: "herdr",
            summary: "Text size in agent-tab terminals.",
            fallback: .number(13),
            owner: "herdr"),
        .init(
            "herdrTerminalMouse", .string, group: "herdr",
            summary: "Mouse input sent to agent-tab terminals: wheel only, or clicks too.",
            allowed: ["scroll", "buttons"],
            fallback: .string("scroll"),
            owner: "herdr"),
        .init(
            "herdrTerminalStartFolder", .string, group: "herdr",
            summary: "Where a new agent-tab terminal starts: the agent's folder or home.",
            allowed: ["agent", "home"],
            fallback: .string("agent"),
            owner: "herdr"),
        .init(
            "herdrTerminalStartupCommand", .string, group: "herdr",
            summary: "Command run in every new agent-tab terminal.",
            fallback: .string(""),
            owner: "herdr"),
        .init(
            "lastBackupAt", .number, group: "backup",
            summary: "Unix timestamp of the last settings backup.",
            readOnly: true),
        .init(
            "lastClipboardBackupAt", .number, group: "backup",
            summary: "Unix timestamp of the last clipboard backup.",
            readOnly: true),
        .init(
            "lastMusicBackupAt", .number, group: "backup",
            summary: "Unix timestamp of the last music backup.",
            readOnly: true),
        .init(
            "menuBarStatsColorHex", .string, group: "menubar",
            summary: "Hex colour of the CPU and memory menu bar readout.",
            owner: "systemStats"),
        .init(
            "menuBarStatsColorMode", .string, group: "menubar",
            summary: "How the CPU and memory menu bar readout is tinted.",
            allowed: ["auto", "custom"],
            fallback: .string("auto"),
            owner: "systemStats"),
        .init(
            "menuBarSystemStats", .bool, group: "menubar",
            summary: "CPU and memory readout as a menu bar item.",
            fallback: .bool(false),
            owner: "systemStats"),
        .init(
            "musicBackup", .bool, group: "music",
            summary: "Include the music folder in the iCloud backup.",
            owner: "music"),
        .init(
            "musicBarAutoHide", .bool, group: "music",
            summary: "Hide the player bar when nothing is playing.",
            fallback: .bool(false),
            owner: "music"),
        .init(
            "musicBarCollapsed", .bool, group: "music",
            summary: "Collapse the player bar to a progress line.",
            fallback: .bool(false),
            owner: "music"),
        .init(
            "musicCrossfadeEnabled", .bool, group: "music",
            summary: "Fade between tracks when one ends.",
            fallback: .bool(true),
            owner: "music"),
        .init(
            "musicCrossfadeSeconds", .number, group: "music",
            summary: "Seconds the crossfade between tracks lasts.",
            fallback: .number(2),
            owner: "music"),
        .init(
            "musicDownloadKind", .string, group: "music",
            summary: "Default format for downloads.",
            allowed: ["post", "images", "audio", "video"],
            fallback: .string("post"),
            owner: "music"),
        .init(
            "musicFavourites", .stringList, group: "music",
            summary: "Relative paths of favourited tracks.",
            owner: "music"),
        .init(
            "musicFolderStale", .bool, group: "music",
            summary: "Whether the stored music folder has gone missing.",
            fallback: .bool(false),
            readOnly: true,
            owner: "music"),
        .init(
            "musicGridView", .bool, group: "music",
            summary: "Show the library as a grid.",
            fallback: .bool(false),
            owner: "music"),
        .init(
            "musicLastPosition", .number, group: "music",
            summary: "Seconds into the track playback resumes from.",
            scope: "standard",
            fallback: .number(0),
            readOnly: true,
            owner: "music"),
        .init(
            "musicLastTrack", .string, group: "music",
            summary: "Relative path of the track playback resumes from.",
            scope: "standard",
            readOnly: true,
            owner: "music"),
        .init(
            "musicLooping", .bool, group: "music",
            summary: "Repeat the current track.",
            scope: "standard",
            fallback: .bool(false),
            owner: "music"),
        .init(
            "musicShuffling", .bool, group: "music",
            summary: "Play the folder in a random order.",
            scope: "standard",
            fallback: .bool(false),
            owner: "music"),
        .init(
            "musicVolume", .number, group: "music",
            summary: "Player volume from 0 to 1.",
            scope: "standard",
            fallback: .number(0.7),
            owner: "music"),
        .init(
            "musicWasPlaying", .bool, group: "music",
            summary: "Whether playback was running when the app last quit.",
            scope: "standard",
            fallback: .bool(false),
            readOnly: true,
            owner: "music"),
        .init(
            "notchAlertAudio", .bool, group: "notch",
            summary: "Alert on audio device changes.",
            owner: "notchShelf"),
        .init(
            "notchAlertBattery", .bool, group: "notch",
            summary: "Alert on battery level changes.",
            owner: "notchShelf"),
        .init(
            "notchAlertBluetooth", .bool, group: "notch",
            summary: "Alert on Bluetooth connections.",
            owner: "notchShelf"),
        .init(
            "notchAlertPower", .bool, group: "notch",
            summary: "Alert on power source changes.",
            owner: "notchShelf"),
        .init(
            "notchAlertsEnabled", .bool, group: "notch",
            summary: "Show alerts around the notch.",
            owner: "notchShelf"),
        .init(
            "notchAudioMixerEnabled", .bool, group: "notch",
            summary: "Audio Mixer ability: per-app volume in the notch shelf.",
            fallback: .bool(false),
            owner: "notchShelf"),
        .init(
            "notchBrowserEnabled", .bool, group: "notch",
            summary: "Notch Shelf browser tab: tabbed browsing in the notch with a Chrome profile.",
            fallback: .bool(false),
            owner: "notchShelf"),
        .init(
            "notchBrowserSearchEngine", .string, group: "notch",
            summary: "Search engine the notch browser address bar uses for plain text.",
            allowed: ["google", "duckDuckGo", "bing", "kagi"],
            fallback: .string("google"),
            owner: "notchShelf"),
        .init(
            "notchShelfEnabled", .bool, group: "notch",
            summary: "Notch Shelf extension: file shelf, now playing, camera and alerts.",
            fallback: .bool(false),
            owner: "notchShelf"),
        .init(
            "notchShelfHaptics", .bool, group: "notch",
            summary: "Haptic feedback on the shelf.",
            owner: "notchShelf"),
        .init(
            "notchShelfKeepDuration", .string, group: "notch",
            summary: "How long shelf items are kept.",
            owner: "notchShelf"),
        .init(
            "notchShelfOpenOnDrag", .bool, group: "notch",
            summary: "Open the shelf when a drag reaches the notch.",
            owner: "notchShelf"),
        .init(
            "notchShelfOpenOnHover", .bool, group: "notch",
            summary: "Open the shelf on hover.",
            owner: "notchShelf"),
        .init(
            "notchShelfRemoveAfterDragOut", .bool, group: "notch",
            summary: "Remove an item from the shelf after it is dragged out.",
            owner: "notchShelf"),
        .init(
            "notchShelfRequireOption", .bool, group: "notch",
            summary: "Require Option held to open the shelf.",
            owner: "notchShelf"),
        .init(
            "notchShelfShowMusic", .bool, group: "notch",
            summary: "Show now playing controls in the shelf.",
            owner: "notchShelf"),
        .init(
            "notchShelfShowOnExternal", .bool, group: "notch",
            summary: "Show the shelf on external displays.",
            owner: "notchShelf"),
        .init(
            "quinjetTerminal", .string, group: "quinjet",
            summary: "Terminal used to launch Quinjet workspaces.",
            allowed: ["embedded", "cmux"],
            fallback: .string("embedded"),
            owner: "quinjet"),
        .init(
            "quinjetTheme", .string, group: "quinjet",
            summary: "Color theme used by embedded Quinjet terminals.",
            fallback: .string("app"),
            owner: "quinjet"),
        .init(
            "skillsAgentSelections", .map, group: "panel",
            summary: "Remember agent selections when installing plugins.",
            fallback: .object([:])),
        .init(
            "studioDestination", .string, group: "studio",
            summary: "Where Studio saves results: next to the original, downloads or a folder.",
            allowed: ["original", "downloads", "folder"],
            fallback: .string("original"),
            owner: "studio"),
        .init(
            "studioFolder", .string, group: "studio",
            summary: "Folder Studio saves results into when the destination is a folder.",
            fallback: .string(""),
            owner: "studio"),
        .init(
            "suiteAgentsEnabled", .bool, group: "suites",
            summary:
                "Agents suite: Usage, live sessions, review and memory for your coding agents.",
            fallback: .bool(false)),
        .init(
            "suiteDataEnabled", .bool, group: "suites",
            summary: "Data suite: Databases, attention history and local site audits.",
            fallback: .bool(false)),
        .init(
            "suiteDeskEnabled", .bool, group: "suites",
            summary:
                "Desk suite: The launcher, clipboard and pickers, keystrokes, dimming and presenting.",
            fallback: .bool(false)),
        .init(
            "suiteMaintenanceEnabled", .bool, group: "suites",
            summary:
                "Maintenance suite: Updates, packages, review-first removal, disk cleanup and history.",
            fallback: .bool(false)),
        .init(
            "suiteMediaEnabled", .bool, group: "suites",
            summary: "Media suite: Studio, music, downloads, the notch shelf and your calendar.",
            fallback: .bool(false)),
        .init(
            "suiteSystemEnabled", .bool, group: "suites",
            summary:
                "System suite: Running apps, sleep, the cleaning lock, menu bar stats and mic mute.",
            fallback: .bool(false)),
        .init(
            "tab", .string, group: "panel",
            summary: "Panel tab shown on open.",
            scope: "standard",
            fallback: .string("usage")),
        .init(
            "tabAttentionEnabled", .bool, group: "attention",
            summary:
                "Attention extension: app and browser activity with focus sessions. Change it with `ed extensions enable`.",
            fallback: .bool(false),
            readOnly: true,
            owner: "attention"),
        .init(
            "tabBlitzTreeEnabled", .bool, group: "panel",
            summary:
                "BlitzTree extension: disk-space treemap and cleanup candidates. Change it with `ed extensions enable`.",
            fallback: .bool(false),
            readOnly: true),
        .init(
            "tabCalendarEnabled", .bool, group: "calendar",
            summary:
                "Calendar extension: your schedule in the panel and the app. Change it with `ed extensions enable`.",
            fallback: .bool(false),
            readOnly: true,
            owner: "calendar"),
        .init(
            "tabCodeStatsEnabled", .bool, group: "codestats",
            summary:
                "Code Stats extension: mirror GitHub repositories and chart your own commits. Change it with `ed extensions enable`.",
            fallback: .bool(false),
            readOnly: true,
            owner: "codeStats"),
        .init(
            "tabCompanionEnabled", .bool, group: "companion",
            summary: "Show the Companion page. Change it with `ed extensions enable`.",
            fallback: .bool(false),
            readOnly: true,
            owner: "companion"),
        .init(
            "tabDatabaseEnabled", .bool, group: "database",
            summary:
                "Database extension: guarded database exploration and operations. Change it with `ed extensions enable`.",
            fallback: .bool(false),
            readOnly: true,
            owner: "database"),
        .init(
            "tabHerdrEnabled", .bool, group: "herdr",
            summary:
                "Herdr extension: live sessions on this Mac and SSH machines. Change it with `ed extensions enable`.",
            fallback: .bool(false),
            readOnly: true,
            owner: "herdr"),
        .init(
            "tabLaTeXEnabled", .bool, group: "latex",
            summary:
                "LaTeX extension: compile documents on disk or through GitHub pull requests. Change it with `ed extensions enable`.",
            fallback: .bool(false),
            readOnly: true,
            owner: "latex"),
        .init(
            "tabMusicEnabled", .bool, group: "music",
            summary:
                "Music extension: local library playback with media keys. Change it with `ed extensions enable`.",
            fallback: .bool(false),
            readOnly: true,
            owner: "music"),
        .init(
            "tabOrder", .csv, group: "panel",
            summary: "Comma separated panel tab order."),
        .init(
            "tabPluginsEnabled", .bool, group: "panel",
            summary: "Show Plugins in the Agents suite. Change it with `ed extensions enable`.",
            fallback: .bool(false),
            readOnly: true),
        .init(
            "tabQuinjetEnabled", .bool, group: "quinjet",
            summary:
                "Quinjet extension: pull request and live workspace review. Change it with `ed extensions enable`.",
            fallback: .bool(false),
            readOnly: true,
            owner: "quinjet"),
        .init(
            "tabSEOAuditEnabled", .bool, group: "panel",
            summary:
                "Site Audit extension: sitemap, metadata, and local Lighthouse reports. Change it with `ed extensions enable`.",
            fallback: .bool(false),
            readOnly: true),
        .init(
            "tabSocialManagerEnabled", .bool, group: "social-manager",
            summary:
                "Social Manager extension: profiles with isolated website accounts, tabs and side-by-side browsing. Change it with `ed extensions enable`.",
            fallback: .bool(false),
            readOnly: true,
            owner: "socialManager"),
        .init(
            "tabStudioEnabled", .bool, group: "studio",
            summary:
                "Studio extension: edit, convert and compress images, PDFs, video and audio. Change it with `ed extensions enable`.",
            fallback: .bool(false),
            readOnly: true,
            owner: "studio"),
        .init(
            "tabTimeLapseEnabled", .bool, group: "studio",
            summary:
                "Screen Recorder extension: record displays or windows at normal speed or as a time-lapse. Change it with `ed extensions enable`.",
            fallback: .bool(false),
            readOnly: true,
            owner: "studio"),
        .init(
            "tabUsageEnabled", .bool, group: "usage",
            summary:
                "Agent Usage extension: Claude, Codex, Cursor and Grok limits, stats and alerts. Change it with `ed extensions enable`.",
            fallback: .bool(false),
            readOnly: true,
            owner: "usage"),
        .init(
            "virtualCameraEnabled", .bool, group: "virtualCamera",
            summary: "Virtual Camera extension: send a framed and styled camera to video apps.",
            fallback: .bool(false),
            owner: "virtualCamera"),
    ]
}
