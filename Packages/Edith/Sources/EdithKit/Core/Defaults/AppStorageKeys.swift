import Foundation

public enum AppStorageKeys {
    public enum General {
        public static let editMainWindowFullScreen = "EdithMainWindowFullScreen"
        public static let appearance = "appearance"
        public static let mainSidebarOpen = "mainSidebarOpen"
        public static let mainSidebarWidth = "mainSidebarWidth"
        public static let mainWindowSection = "mainWindowSection"
        public static let settingsTab = "settingsTab"
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
        public static let preventSleep = "preventSleep"
    }

    public enum Backup {
        public static let limits = "backupLimits"
        public static let settings = "backupSettings"
        public static let usage = "backupUsage"
        public static let icloud = "icloudBackup"
        public static let lastBackupAt = "lastBackupAt"
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

    public enum FocusDim {
        public static let animationDuration = "focusDimAnimationDuration"
        public static let hotKeyCode = "focusDimHotKeyCode"
        public static let hotKeyLabel = "focusDimHotKeyLabel"
        public static let hotKeyMods = "focusDimHotKeyMods"
        public static let intensity = "focusDimIntensity"
        public static let otherDisplaysMode = "focusDimOtherDisplaysMode"
    }

    public enum Limits {
        public static let claudeEnabled = "claudeLimitsEnabled"
        public static let codexEnabled = "codexLimitsEnabled"
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

    public enum MenuBar {
        public static let claudeWindows = "menuBarClaudeWindows"
        public static let codexWindows = "menuBarCodexWindows"
        public static let colorMode = "menuBarColorMode"
        public static let limitsStyle = "menuBarLimitsStyle"
        public static let highColorHex = "menuBarHighColorHex"
        public static let lowColorHex = "menuBarLowColorHex"
        public static let midColorHex = "menuBarMidColorHex"
        public static let statsColorHex = "menuBarStatsColorHex"
        public static let subColorHex = "menuBarSubColorHex"
        public static let systemStats = "menuBarSystemStats"
    }

    public enum Mic {
        public static let muteEnabled = "micMuteEnabled"
        public static let muteInMenuBar = "micMuteInMenuBar"
    }

    public enum Music {
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
        public static let master = "notifyMaster"
        public static let pacingHot = "notifyPacingHot"
        public static let pacingWarning = "notifyPacingWarning"
        public static let recovery = "notifyRecovery"
        public static let reminderSession = "notifyReminderSession"
        public static let reminderSessionOffsetMin = "notifyReminderSessionOffsetMin"
        public static let reminderWeekly = "notifyReminderWeekly"
        public static let reminderWeeklyOffsetMin = "notifyReminderWeeklyOffsetMin"
        public static let tokenExpired = "notifyTokenExpired"
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

    public enum Tabs {
        public static let calendarEnabled = "tabCalendarEnabled"
        public static let companionEnabled = "tabCompanionEnabled"
        public static let herdrEnabled = "tabHerdrEnabled"
        public static let machinesEnabled = "tabMachinesEnabled"
        public static let musicEnabled = "tabMusicEnabled"
        public static let order = "tabOrder"
        public static let systemEnabled = "tabSystemEnabled"
        public static let usageEnabled = "tabUsageEnabled"
    }
}
