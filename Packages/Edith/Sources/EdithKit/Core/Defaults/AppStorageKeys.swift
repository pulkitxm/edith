import Foundation

public enum AppStorageKeys {
    public enum Suites {
        public static let agents = "suiteAgentsEnabled"
        public static let maintenance = "suiteMaintenanceEnabled"
        public static let system = "suiteSystemEnabled"
        public static let desk = "suiteDeskEnabled"
        public static let media = "suiteMediaEnabled"
        public static let data = "suiteDataEnabled"
    }

    public enum AppMaintenance {
        public static let categoriesExpanded = "appMaintenanceCategoriesExpanded"
        public static let enabled = "appMaintenanceEnabled"
        public static let installDestination = "appMaintenanceInstallDestination"
        public static let section = "appMaintenanceSection"
        public static let updateAutoRefresh = "appUpdateAutoRefresh"
        public static let updateConcurrency = "appUpdateConcurrency"
        public static let updateNotifications = "appUpdateNotifications"
        public static let updateRefreshInterval = "appUpdateRefreshInterval"
        public static let updateRetries = "appUpdateRetries"
    }

    public enum Update {
        public static let automaticChecks = "SUEnableAutomaticChecks"
        public static let checkInterval = "SUScheduledCheckInterval"
        public static let automaticDownloads = "SUAutomaticallyUpdate"
    }

    public enum General {
        public static let editMainWindowFullScreen = "EdithMainWindowFullScreen"
        public static let appearance = "appearance"
        public static let mainSidebarOpen = "mainSidebarOpen"
        public static let mainSidebarWidth = "mainSidebarWidth"
        public static let settingsCategoriesExpanded = "settingsCategoriesExpanded"
        public static let mainWindowSection = "mainWindowSection"
        public static let settingsTab = "settingsTab"
        public static let settingsSection = "settingsSection"
        public static let showDockIcon = "showDockIcon"
        public static let smartColor = "smartColor"
        public static let theme = "theme"
        public static let lastPaletteTheme = "lastPaletteTheme"
        public static let creditHidden = "creditHidden"
        public static let homeClockZones = "homeClockZones"
        public static let hotKeyCode = "hotKeyCode"
        public static let hotKeyLabel = "hotKeyLabel"
        public static let hotKeyMods = "hotKeyMods"
        public static let panelTab = "tab"
        public static let keepAwakeEnabled = "keepAwakeEnabled"
        public static let preventSleep = "preventSleep"
    }

    public enum Backup {
        public static let limits = "backupLimits"
        public static let settings = "backupSettings"
        public static let usage = "backupUsage"
        public static let icloud = "icloudBackup"
        public static let lastBackupAt = "lastBackupAt"
    }

    public enum Bifrost {
        public static let enabled = "bifrostEnabled"
        public static let hotKeyCode = "bifrostHotKeyCode"
        public static let hotKeyLabel = "bifrostHotKeyLabel"
        public static let hotKeyMods = "bifrostHotKeyMods"
        public static let indexedAt = "bifrostIndexedAt"
        public static let pasteSnippets = "bifrostPasteSnippets"
        public static let popupAt = "bifrostPopupAt"
        public static let quicklinks = "bifrostQuicklinks"
        public static let resultLimit = "bifrostResultLimit"
        public static let shellCommands = "bifrostShellCommands"
        public static let snippets = "bifrostSnippets"
        public static let sourceAppleShortcuts = "bifrostSourceAppleShortcuts"
        public static let sourceOpenWindows = "bifrostSourceOpenWindows"
        public static let sourceQuicklinks = "bifrostSourceQuicklinks"
        public static let sourceRunningApplications = "bifrostSourceRunningApplications"
        public static let sourceShellCommands = "bifrostSourceShellCommands"
        public static let sourceSnippets = "bifrostSourceSnippets"
        public static let sourceSystemActions = "bifrostSourceSystemActions"
        public static let sourceWindowActions = "bifrostSourceWindowActions"
        public static let usage = "bifrostUsage"
    }

    public enum Budget {
        public static let capPercent = "budgetCapPercent"
        public static let deadline = "budgetDeadline"
        public static let enabled = "budgetEnabled"
        public static let kind = "budgetKind"
        public static let mode = "budgetMode"
    }

    public enum Clipboard {
        public static let autoPaste = "clipboardAutoPaste"
        public static let backup = "clipboardBackup"
        public static let capturePaused = "clipboardCapturePaused"
        public static let checkInterval = "clipboardCheckInterval"
        public static let enabled = "clipboardEnabled"
        public static let ignoredApps = "clipboardIgnoredApps"
        public static let maxAgeDays = "clipboardMaxAgeDays"
        public static let maxItemBytes = "clipboardMaxItemBytes"
        public static let maxItems = "clipboardMaxItems"
        public static let pastePlainText = "clipboardPastePlainText"
        public static let pinTo = "clipboardPinTo"
        public static let popupAt = "clipboardPopupAt"
        public static let saveFiles = "clipboardSaveFiles"
        public static let saveImages = "clipboardSaveImages"
        public static let saveText = "clipboardSaveText"
        public static let showFooter = "clipboardShowFooter"
        public static let lastBackupAt = "lastClipboardBackupAt"
    }

    public enum ColorPicker {
        public static let copyFormat = "colorPickerCopyFormat"
        public static let enabled = "colorPickerEnabled"
        public static let historySize = "colorPickerHistorySize"
        public static let profile = "colorPickerProfile"
    }

    public enum Companion {
        public static let endpoint = "companionEndpoint"
        public static let tab = "companionTab"
        public static let setupDeclined = "companionSetupDeclined"
    }

    public enum Emoji {
        public static let enabled = "emojiEnabled"
        public static let frequentCount = "emojiFrequentCount"
        public static let hotKeyCode = "emojiHotKeyCode"
        public static let hotKeyLabel = "emojiHotKeyLabel"
        public static let hotKeyMods = "emojiHotKeyMods"
        public static let popupAt = "emojiPopupAt"
        public static let skinTone = "emojiSkinTone"
        public static let usage = "emojiUsage"
    }

    public enum FocusDim {
        public static let animationDuration = "focusDimAnimationDuration"
        public static let hotKeyCode = "focusDimHotKeyCode"
        public static let hotKeyLabel = "focusDimHotKeyLabel"
        public static let hotKeyMods = "focusDimHotKeyMods"
        public static let intensity = "focusDimIntensity"
        public static let otherDisplaysMode = "focusDimOtherDisplaysMode"
    }

    public enum Jev {
        public static let configured = "jevConfigured"
    }

    public enum Herdr {
        public static let agentViews = "herdrAgentViews"
        public static let ghosttyTerminal = "herdrGhosttyTerminal"
        public static let splitFraction = "herdrSplitFraction"
        public static let railOpen = "herdrRailOpen"
        public static let railWidth = "herdrRailWidth"
        public static let detailOpen = "herdrDetailOpen"
        public static let detailWidth = "herdrDetailWidth"
        public static let agentsCollapsed = "herdrAgentsCollapsed"
        public static let agentsCollapsedCount = "herdrAgentsCollapsedCount"
        public static let terminalsCollapsed = "herdrTerminalsCollapsed"
        public static let terminalsCollapsedCount = "herdrTerminalsCollapsedCount"
        public static let spaceGroupingEnabled = "herdrSpaceGroupingEnabled"
        public static let collapsedSpaces = "herdrCollapsedSpaces"
        public static let collapsedSpaceCounts = "herdrCollapsedSpaceCounts"
        public static let savedArrangements = "herdrSavedArrangements"
        public static let animatesLayout = "herdrAnimatesLayout"
        public static let launchCommands = "herdrLaunchCommands"
        public static let pendingOpen = "herdrPendingOpen"
        public static let launchDefaults = "herdrLaunchDefaults"
        public static let terminalPanelHeight = "herdrTerminalPanelHeight"
        public static let terminalMouse = "herdrTerminalMouse"
        public static let terminalFontSize = "herdrTerminalFontSize"
        public static let terminalStartFolder = "herdrTerminalStartFolder"
        public static let terminalStartupCommand = "herdrTerminalStartupCommand"
        public static let terminalConfirmClose = "herdrTerminalConfirmClose"
    }

    public enum Cleaner {
        public static let enabled = "cleanerEnabled"
    }

    public enum Downloads {
        public static let enabled = "downloadsEnabled"
    }

    public enum Homebrew {
        public static let defaultKind = "homebrewDefaultKind"
        public static let enabled = "homebrewEnabled"
    }

    public enum KeystrokeHighlight {
        public static let active = "keystrokeHighlightActive"
        public static let duration = "keystrokeHighlightDuration"
        public static let enabled = "keystrokeHighlightEnabled"
        public static let hotKeyCode = "keystrokeHighlightHotKeyCode"
        public static let hotKeyLabel = "keystrokeHighlightHotKeyLabel"
        public static let hotKeyMods = "keystrokeHighlightHotKeyMods"
        public static let position = "keystrokeHighlightPosition"
        public static let runtimeActive = "keystrokeHighlightRuntimeActive"
        public static let runtimeError = "keystrokeHighlightRuntimeError"
    }

    public enum Limits {
        public static let claudeEnabled = "claudeLimitsEnabled"
        public static let codexEnabled = "codexLimitsEnabled"
        public static let cursorEnabled = "cursorLimitsEnabled"
        public static let critPercent = "critPercent"
        public static let inMenuBar = "limitsInMenuBar"
        public static let provider = "limitsProvider"
        public static let pacingMargin = "pacingMargin"
        public static let warnPercent = "warnPercent"
    }

    public enum Machines {
        public static let autoConnect = "machinesAutoConnect"
        public static let diskThreshold = "machinesDiskThreshold"
        public static let mode = "machinesMode"
        public static let notifyDiskFull = "machinesNotifyDiskFull"
        public static let notifyDown = "machinesNotifyDown"
        public static let selection = "machinesSelection"
        public static let tab = "machinesTab"
    }

    public enum Quinjet {
        public static let terminal = "quinjetTerminal"
        public static let theme = "quinjetTheme"
    }

    public enum MenuBar {
        public static let claudeWindows = "menuBarClaudeWindows"
        public static let codexWindows = "menuBarCodexWindows"
        public static let cursorWindows = "menuBarCursorWindows"
        public static let colorMode = "menuBarColorMode"
        public static let limitsStyle = "menuBarLimitsStyle"
        public static let highColorHex = "menuBarHighColorHex"
        public static let lowColorHex = "menuBarLowColorHex"
        public static let midColorHex = "menuBarMidColorHex"
        public static let statsColorHex = "menuBarStatsColorHex"
        public static let statsColorMode = "menuBarStatsColorMode"
        public static let subColorHex = "menuBarSubColorHex"
        public static let systemStats = "menuBarSystemStats"
    }

    public enum Mic {
        public static let muteEnabled = "micMuteEnabled"
        public static let muteInMenuBar = "micMuteInMenuBar"
    }

    public enum Music {
        public static let barAutoHide = "musicBarAutoHide"
        public static let barCollapsed = "musicBarCollapsed"
        public static let lastBackupAt = "lastMusicBackupAt"
        public static let backup = "musicBackup"
        public static let downloadKind = "musicDownloadKind"
        public static let gridView = "musicGridView"
        public static let volume = "musicVolume"
        public static let looping = "musicLooping"
        public static let shuffling = "musicShuffling"
    }

    public enum Notch {
        public static let alertAudio = "notchAlertAudio"
        public static let alertBattery = "notchAlertBattery"
        public static let alertBluetooth = "notchAlertBluetooth"
        public static let alertPower = "notchAlertPower"
        public static let alertsEnabled = "notchAlertsEnabled"
        public static let audioMixerEnabled = "notchAudioMixerEnabled"
        public static let browserEnabled = "notchBrowserEnabled"
        public static let browserSearchEngine = "notchBrowserSearchEngine"
        public static let shelfEnabled = "notchShelfEnabled"
        public static let shelfHaptics = "notchShelfHaptics"
        public static let shelfKeepDuration = "notchShelfKeepDuration"
        public static let shelfOpenOnDrag = "notchShelfOpenOnDrag"
        public static let shelfOpenOnHover = "notchShelfOpenOnHover"
        public static let shelfRemoveAfterDragOut = "notchShelfRemoveAfterDragOut"
        public static let shelfRequireOption = "notchShelfRequireOption"
        public static let shelfShowMusic = "notchShelfShowMusic"
        public static let shelfShowOnExternal = "notchShelfShowOnExternal"
    }

    public enum Notify {
        public static let almostCapped = "notifyAlmostCapped"
        public static let almostCappedPercent = "notifyAlmostCappedPercent"
        public static let back = "notifyBack"
        public static let capped = "notifyCapped"
        public static let headroom = "notifyHeadroom"
        public static let loginProblems = "notifyLoginProblems"
        public static let master = "notifyMaster"
        public static let onPace = "notifyOnPace"
        public static let outlook = "notifyOutlook"
        public static let trackSession = "notifyTrackSession"
        public static let trackWeekly = "notifyTrackWeekly"
    }

    public enum Permissions {
        public static let accessibilityGranted = "permAccessibilityGranted"
        public static let calendarGranted = "permCalendarGranted"
        public static let cameraGranted = "permCameraGranted"
        public static let filter = "permissionsFilter"
        public static let fullDiskGranted = "permFullDiskGranted"
        public static let inputMonitoringGranted = "permInputMonitoringGranted"
        public static let notificationsGranted = "permNotificationsGranted"
        public static let screenRecordingGranted = "permScreenRecordingGranted"
    }

    public enum Presenter {
        public static let askJev = "presenterAskJev"
        public static let autoActive = "presenterAutoActive"
        public static let autoEnabled = "presenterAutoEnabled"
        public static let autoPaused = "presenterAutoPaused"
        public static let autoReason = "presenterAutoReason"
        public static let blurAgents = "presenterBlurAgents"
        public static let blurCalendar = "presenterBlurCalendar"
        public static let blurMoney = "presenterBlurMoney"
        public static let blurMusic = "presenterBlurMusic"
        public static let blurUsage = "presenterBlurUsage"
        public static let detectMirroring = "presenterDetectMirroring"
        public static let detectRecording = "presenterDetectRecording"
        public static let detectScreenSharing = "presenterDetectScreenSharing"
        public static let enabled = "presenterEnabled"
        public static let hideMenuBarNumbers = "presenterHideMenuBarNumbers"
        public static let mode = "presenterMode"
    }

    public enum Skills {
        public static let agentSelections = "skillsAgentSelections"
    }

    public enum Studio {
        public static let destination = "studioDestination"
        public static let folder = "studioFolder"
        public static let library = "studioLibrary"
    }

    public enum Tabs {
        public static let attentionEnabled = "tabAttentionEnabled"
        public static let calendarEnabled = "tabCalendarEnabled"
        public static let companionEnabled = "tabCompanionEnabled"
        public static let pluginsEnabled = "tabPluginsEnabled"
        public static let databaseEnabled = "tabDatabaseEnabled"
        public static let herdrEnabled = "tabHerdrEnabled"
        public static let musicEnabled = "tabMusicEnabled"
        public static let studioEnabled = "tabStudioEnabled"
        public static let order = "tabOrder"
        public static let quinjetEnabled = "tabQuinjetEnabled"
        public static let seoAuditEnabled = "tabSEOAuditEnabled"
        public static let systemEnabled = "tabSystemEnabled"
        public static let usageEnabled = "tabUsageEnabled"
    }
    public enum VirtualCamera {
        public static let enabled = "virtualCameraEnabled"
        public static let state = "virtualCameraState"
        public static let hotKeyCode = "virtualCameraHotKeyCode"
        public static let hotKeyMods = "virtualCameraHotKeyMods"
        public static let hotKeyLabel = "virtualCameraHotKeyLabel"
    }

    public enum WindowSweaters {
        public static let enabled = "windowSweatersEnabled"
        public static let active = "windowSweatersActive"
        public static let accessibilityFocus = "windowSweatersAccessibilityFocus"
        public static let anchor = "windowSweatersAnchor"
        public static let basket = "windowSweatersBasket"
        public static let borderWidth = "windowSweatersBorderWidth"
        public static let excludedApps = "windowSweatersExcludedApps"
        public static let gauge = "windowSweatersGauge"
        public static let order = "windowSweatersOrder"
        public static let pattern = "windowSweatersPattern"
        public static let stitch = "windowSweatersStitch"
        public static let unfocusedDim = "windowSweatersUnfocusedDim"
    }
}
