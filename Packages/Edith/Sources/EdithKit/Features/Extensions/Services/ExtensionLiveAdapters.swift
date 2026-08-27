import AppKit
import CoreAudio
import EdithCore
import EventKit
import Foundation
import ServiceManagement

struct ExtensionAdapterFacts: Equatable, Sendable {
    let installed: Bool
    let configured: Bool
    let contentCount: Int?
    let loading: Bool
    let unsupportedReason: String?
    let failure: String?
    let degradedReason: String?
    let readyDetail: String
    let uninstalledDetail: String
    let setupDetail: String
    let emptyDetail: String
    let loadingDetail: String

    init(
        installed: Bool = true, configured: Bool = true, contentCount: Int? = nil,
        loading: Bool = false, unsupportedReason: String? = nil, failure: String? = nil,
        degradedReason: String? = nil, readyDetail: String,
        uninstalledDetail: String = "The extension runtime is not installed.",
        setupDetail: String = "The extension runtime needs configuration.",
        emptyDetail: String = "The extension is ready, but has no content yet.",
        loadingDetail: String = "The extension runtime is loading."
    ) {
        self.installed = installed
        self.configured = configured
        self.contentCount = contentCount
        self.loading = loading
        self.unsupportedReason = unsupportedReason
        self.failure = failure
        self.degradedReason = degradedReason
        self.readyDetail = readyDetail
        self.uninstalledDetail = uninstalledDetail
        self.setupDetail = setupDetail
        self.emptyDetail = emptyDetail
        self.loadingDetail = loadingDetail
    }

    var readiness: ExtensionAdapterReadiness {
        if let unsupportedReason { return .unsupported(unsupportedReason) }
        if let failure { return .failed(failure) }
        if !installed { return .uninstalled(uninstalledDetail) }
        if loading { return .loading(loadingDetail) }
        if !configured { return .needsSetup(setupDetail) }
        if contentCount == 0 { return .empty(emptyDetail) }
        if let degradedReason { return .degraded(degradedReason) }
        return .ready(readyDetail)
    }
}

private final class ExtensionAdapterDefaults: @unchecked Sendable {
    let store: UserDefaults

    init(_ store: UserDefaults) {
        self.store = store
    }
}

public enum ExtensionLiveAdapters {
    public static let extensionIDs = [
        "attention", "usage", "quinjet", "system", "machines", "systemStats", "micMute",
        "lidAwake", "music", "calendar", "notchShelf", "clipboard", "finderTools", "focusDim",
        "presenter", "emoji", "colorPicker", "windowTools",
    ]

    public static func provider(
        defaults: UserDefaults = SharedDefaults.store,
        executableNamed: @escaping @Sendable (String) -> URL? = {
            CLIToolEnvironment.executable(named: $0)
        }
    ) -> @Sendable (String) async -> ExtensionAdapterReadiness? {
        let defaults = ExtensionAdapterDefaults(defaults)
        return {
            id in
            await readiness(
                for: id, defaults: defaults.store, executableNamed: executableNamed)
        }
    }

    public static func readiness(
        for id: String, defaults: UserDefaults = SharedDefaults.store,
        executableNamed: @Sendable (String) -> URL? = {
            CLIToolEnvironment.executable(named: $0)
        }
    ) async -> ExtensionAdapterReadiness? {
        switch id {
        case "attention": attentionReadiness()
        case "usage": usageReadiness()
        case "quinjet":
            quinjetReadiness(defaults: defaults, executable: executableNamed("quinjet"))
        case "system": await systemReadiness()
        case "machines": machinesReadiness()
        case "systemStats": systemStatsReadiness()
        case "micMute": microphoneReadiness()
        case "lidAwake": lidAwakeReadiness()
        case "music": musicReadiness()
        case "calendar": calendarReadiness()
        case "notchShelf": shelfReadiness()
        case "clipboard": clipboardReadiness()
        case "finderTools": finderToolsReadiness(defaults: defaults)
        case "focusDim": await focusDimReadiness(defaults: defaults)
        case "presenter": presenterReadiness(defaults: defaults)
        case "colorPicker": await colorPickerReadiness(defaults: defaults)
        case "windowTools": windowToolsReadiness(defaults: defaults)
        case "emoji": emojiReadiness(defaults: defaults)
        default: nil
        }
    }

    static func finderToolsReadiness(defaults: UserDefaults) -> ExtensionAdapterReadiness {
        let keys = [
            AppStorageKeys.FinderTools.cutPaste, AppStorageKeys.FinderTools.rename,
            AppStorageKeys.FinderTools.pasteImages, AppStorageKeys.FinderTools.diskImageInstaller,
        ]
        let enabled = keys.filter { defaults.object(forKey: $0) as? Bool ?? true }
        return ExtensionAdapterFacts(
            configured: !enabled.isEmpty,
            readyDetail: "Finder Tools features enabled: \(enabled.count).",
            setupDetail: "Turn on at least one Finder Tools feature."
        ).readiness
    }

    static func attentionReadiness(
        settings: AttentionSettings = AttentionRepository().loadSettings()
    ) -> ExtensionAdapterReadiness {
        let configured =
            settings.isEnabled
            && (settings.trackingEnabled || settings.browserTrackingEnabled)
        return ExtensionAdapterFacts(
            configured: configured,
            readyDetail: "Attention tracking is configured for the selected sources.",
            setupDetail: "Turn on application tracking, browser tracking, or both."
        ).readiness
    }

    static func usageReadiness(
        script: URL? = UsageRefreshRunner.scriptURL(), data: URL = Repo.usageJSON,
        loading: Bool = UsageRefreshRunner.isRunning
    ) -> ExtensionAdapterReadiness {
        guard script != nil else {
            return ExtensionAdapterFacts(
                installed: false, readyDetail: "Usage collection is ready.",
                uninstalledDetail: "The bundled usage collector is missing."
            ).readiness
        }
        if loading {
            return ExtensionAdapterFacts(
                loading: true, readyDetail: "Usage collection is ready.",
                loadingDetail: "Usage providers are being refreshed."
            ).readiness
        }
        guard FileManager.default.fileExists(atPath: data.path) else {
            return ExtensionAdapterFacts(
                contentCount: 0, readyDetail: "Usage collection is ready.",
                emptyDetail: "No usage sample has been collected yet."
            ).readiness
        }
        do {
            let value = try JSONSerialization.jsonObject(with: Data(contentsOf: data))
            guard let document = value as? [String: Any] else {
                throw ExtensionAdapterError.invalid("Usage data is not a JSON object.")
            }
            let days = document["daily"] as? [Any] ?? []
            return ExtensionAdapterFacts(
                contentCount: days.count, readyDetail: "Usage data is readable and current.",
                emptyDetail: "Usage data is valid, but contains no daily samples."
            ).readiness
        } catch {
            return .failed("Usage data could not be read: \(error.localizedDescription)")
        }
    }

    static func quinjetReadiness(
        defaults: UserDefaults, executable: URL? = CLIToolEnvironment.executable(named: "quinjet"),
        cmux: URL? = QuinjetCMUX.executable()
    ) -> ExtensionAdapterReadiness {
        let terminalRaw = defaults.string(forKey: AppStorageKeys.Quinjet.terminal)
        let themeRaw = defaults.string(forKey: AppStorageKeys.Quinjet.theme)
        let terminalValid = terminalRaw == nil || QuinjetTerminal(rawValue: terminalRaw!) != nil
        let themeValid =
            themeRaw.map {
                $0 == QuinjetThemePreference.app || QuinjetTheme(rawValue: $0) != nil
            } ?? true
        let terminal = terminalRaw.flatMap(QuinjetTerminal.init(rawValue:)) ?? .embedded
        let configured = terminalValid && themeValid && (terminal != .cmux || cmux != nil)
        return ExtensionAdapterFacts(
            installed: executable != nil, configured: configured,
            readyDetail: "Quinjet and its \(terminal.rawValue) terminal are ready.",
            uninstalledDetail: "The Quinjet executable is not installed.",
            setupDetail: terminal == .cmux && cmux == nil
                ? "cmux is selected, but cmux is not installed in Applications."
                : "The stored Quinjet terminal or theme is invalid."
        ).readiness
    }

    static func systemReadiness() async -> ExtensionAdapterReadiness {
        let count = await MainActor.run {
            NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.count
        }
        return ExtensionAdapterFacts(
            contentCount: count, readyDetail: "Running application control is available.",
            emptyDetail: "No regular applications are visible to the system runtime."
        ).readiness
    }

    static func machinesReadiness(file: URL = MachinePaths.machinesFile)
        -> ExtensionAdapterReadiness
    {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return ExtensionAdapterFacts(
                contentCount: 0, readyDetail: "Machine configuration is valid.",
                emptyDetail: "No SSH machines are configured."
            ).readiness
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let machines = try decoder.decode([Machine].self, from: Data(contentsOf: file))
            let configured = machines.allSatisfy {
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !$0.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && (1...65_535).contains($0.port)
            }
            return ExtensionAdapterFacts(
                configured: configured, contentCount: machines.count,
                readyDetail: "Configured machines: \(machines.count).",
                setupDetail: "A machine has an empty name or host, or an invalid SSH port.",
                emptyDetail: "No SSH machines are configured."
            ).readiness
        } catch {
            return .failed(
                "Machine configuration could not be read: \(error.localizedDescription)")
        }
    }

    static func systemStatsReadiness(
        ticks: CPUTicks? = SystemStatsReader.readCPUTicks(),
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> ExtensionAdapterReadiness {
        ExtensionAdapterFacts(
            unsupportedReason: physicalMemory == 0
                ? "Physical memory metrics are unavailable." : nil,
            failure: ticks == nil ? "CPU metrics could not be sampled." : nil,
            readyDetail: "CPU and memory metrics can be sampled."
        ).readiness
    }

    static func microphoneReadiness(
        devices: Result<Int, ExtensionAdapterError> = inputDeviceCount()
    ) -> ExtensionAdapterReadiness {
        switch devices {
        case let .success(count):
            return ExtensionAdapterFacts(
                contentCount: count, readyDetail: "Controllable microphone inputs: \(count).",
                emptyDetail: "No microphone input device is available."
            ).readiness
        case let .failure(error):
            return .failed(error.localizedDescription)
        }
    }

    static func lidAwakeReadiness(
        status: SMAppService.Status = SMAppService.daemon(
            plistName: LidAwakePrivilegedService.plistName
        ).status
    ) -> ExtensionAdapterReadiness {
        switch status {
        case .enabled:
            return .ready("The privileged sleep helper is registered and enabled.")
        case .requiresApproval:
            return .needsSetup(
                "The sleep helper needs approval in System Settings > General > Login Items.")
        case .notRegistered:
            return .uninstalled("The privileged sleep helper is not registered.")
        case .notFound:
            return .uninstalled("The privileged sleep helper is missing from Edith.app.")
        @unknown default:
            return .unsupported("This macOS version returned an unknown helper status.")
        }
    }

    static func musicReadiness(directory: URL = Repo.musicDir) -> ExtensionAdapterReadiness {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
        else {
            return .uninstalled("The configured music library folder does not exist.")
        }
        guard isDirectory.boolValue else {
            return .failed("The configured music library path is not a folder.")
        }
        var failure: Error?
        var count = 0
        let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) { _, error in
            failure = error
            return false
        }
        guard let enumerator else {
            return .failed("The music library could not be scanned.")
        }
        for case let file as URL in enumerator {
            guard TrackMeta.playableExtensions.contains(file.pathExtension.lowercased()) else {
                continue
            }
            count += 1
        }
        if let failure {
            return .failed(
                "The music library could not be scanned: \(failure.localizedDescription)")
        }
        return ExtensionAdapterFacts(
            contentCount: count, readyDetail: "Playable tracks in the library: \(count).",
            emptyDetail: "The music library contains no supported audio files."
        ).readiness
    }

    static func calendarReadiness(
        status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event),
        calendarCount: (() -> Int)? = nil
    ) -> ExtensionAdapterReadiness {
        switch status {
        case .fullAccess, .authorized:
            let count = calendarCount?() ?? EKEventStore().calendars(for: .event).count
            return ExtensionAdapterFacts(
                contentCount: count, readyDetail: "Readable calendars: \(count).",
                emptyDetail: "Calendar access is granted, but no calendars are available."
            ).readiness
        case .notDetermined:
            return .needsSetup("Calendar access has not been requested.")
        case .denied:
            return .needsSetup("Calendar access is denied in System Settings.")
        case .restricted, .writeOnly:
            return .unsupported("macOS does not allow Edith to read calendar events.")
        @unknown default:
            return .unsupported("This macOS version returned an unknown Calendar access state.")
        }
    }

    static func shelfReadiness(root: URL = ShelfIndex.root) -> ExtensionAdapterReadiness {
        do {
            let items = try ShelfMutationExecution.snapshot(root: root).items
            let missing = items.filter {
                !FileManager.default.fileExists(atPath: ShelfIndex.fileURL(for: $0, in: root).path)
            }.count
            return ExtensionAdapterFacts(
                contentCount: items.count,
                degradedReason: missing > 0 ? "Shelf items missing on disk: \(missing)." : nil,
                readyDetail: "Parked shelf files: \(items.count).",
                emptyDetail: "The shelf is ready and has no parked files."
            ).readiness
        } catch {
            return .failed("The shelf index could not be read: \(error.localizedDescription)")
        }
    }

    static func clipboardReadiness(
        index: URL = ClipboardPaths.indexFile, blobs: URL = ClipboardPaths.blobsDir
    ) -> ExtensionAdapterReadiness {
        guard FileManager.default.fileExists(atPath: index.path) else {
            return ExtensionAdapterFacts(
                contentCount: 0, readyDetail: "Clipboard storage is readable.",
                emptyDetail: "Clipboard history is ready and empty."
            ).readiness
        }
        do {
            let text = try String(contentsOf: index, encoding: .utf8)
            let lines = text.split(whereSeparator: \.isNewline)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let entries = try lines.map {
                try decoder.decode(ClipboardEntry.self, from: Data($0.utf8))
            }
            let missing = entries.filter {
                !FileManager.default.fileExists(
                    atPath: blobs.appendingPathComponent("\($0.sha256).\($0.ext)").path)
            }.count
            return ExtensionAdapterFacts(
                contentCount: entries.count,
                degradedReason: missing > 0
                    ? "Clipboard entries missing payloads: \(missing)." : nil,
                readyDetail: "Clipboard history entries: \(entries.count).",
                emptyDetail: "Clipboard history is ready and empty."
            ).readiness
        } catch {
            return .failed(
                "Clipboard storage could not be read: \(error.localizedDescription)")
        }
    }

    static func focusDimReadiness(defaults: UserDefaults) async -> ExtensionAdapterReadiness {
        let intensity = defaults.object(forKey: AppStorageKeys.FocusDim.intensity) as? Double
        let duration = defaults.object(forKey: AppStorageKeys.FocusDim.animationDuration) as? Double
        let mode = defaults.string(forKey: AppStorageKeys.FocusDim.otherDisplaysMode)
        let configured =
            (intensity == nil || intensity!.isFinite)
            && (duration == nil || duration!.isFinite)
            && (mode == nil || FocusDimDisplayMode(rawValue: mode!) != nil)
        let screenCount = await MainActor.run { NSScreen.screens.count }
        return ExtensionAdapterFacts(
            configured: configured, contentCount: screenCount,
            readyDetail: "Focus Dim can manage \(screenCount) display(s).",
            setupDetail: "A stored dim intensity, animation duration, or display mode is invalid.",
            emptyDetail: "No active display is available for Focus Dim."
        ).readiness
    }

    static func presenterReadiness(defaults: UserDefaults) -> ExtensionAdapterReadiness {
        let auto = defaults.object(forKey: AppStorageKeys.Presenter.autoEnabled) as? Bool ?? false
        let detectionEnabled = [
            (AppStorageKeys.Presenter.detectRecording, true),
            (AppStorageKeys.Presenter.detectScreenSharing, true),
            (AppStorageKeys.Presenter.detectMirroring, true),
        ].contains { key, fallback in
            defaults.object(forKey: key) as? Bool ?? fallback
        }
        let protected = [
            (AppStorageKeys.Presenter.blurAgents, true),
            (AppStorageKeys.Presenter.blurCalendar, true),
            (AppStorageKeys.Presenter.blurMoney, true),
            (AppStorageKeys.Presenter.blurMusic, true),
            (AppStorageKeys.Presenter.blurUsage, false),
        ].filter { key, fallback in
            defaults.object(forKey: key) as? Bool ?? fallback
        }.count
        return ExtensionAdapterFacts(
            configured: protected > 0,
            degradedReason: auto && !detectionEnabled
                ? "Automatic Presenter mode is on, but every detector is off." : nil,
            readyDetail: "Presenter protects \(protected) data categories.",
            setupDetail: "Presenter has no protected data categories enabled."
        ).readiness
    }

    static func colorPickerReadiness(defaults: UserDefaults) async -> ExtensionAdapterReadiness {
        let formatRaw = defaults.string(forKey: AppStorageKeys.ColorPicker.copyFormat)
        let profileRaw = defaults.string(forKey: AppStorageKeys.ColorPicker.profile)
        let historySize = defaults.object(forKey: AppStorageKeys.ColorPicker.historySize) as? Int
        let configured =
            (formatRaw == nil || ColorCopyFormat(rawValue: formatRaw!) != nil)
            && (profileRaw == nil || ColorProfile(rawValue: profileRaw!) != nil)
            && (historySize == nil || (1...100).contains(historySize!))
        let data = defaults.data(forKey: "colorPickerHistory")
        let history: [ColorSwatch]
        do {
            history = try data.map { try JSONDecoder().decode([ColorSwatch].self, from: $0) } ?? []
        } catch {
            return .failed("Color history could not be read: \(error.localizedDescription)")
        }
        let screenCount = await MainActor.run { NSScreen.screens.count }
        return ExtensionAdapterFacts(
            configured: configured, contentCount: screenCount == 0 ? 0 : history.count,
            readyDetail: "Saved color samples: \(history.count).",
            setupDetail: "The stored color format, profile, or history size is invalid.",
            emptyDetail: screenCount == 0
                ? "No active display is available for color sampling."
                : "Color sampling is ready and the history is empty."
        ).readiness
    }

    static func windowToolsReadiness(defaults: UserDefaults) -> ExtensionAdapterReadiness {
        let integerKeys = [
            AppStorageKeys.WindowTools.leftHotKeyCode,
            AppStorageKeys.WindowTools.leftHotKeyMods,
            AppStorageKeys.WindowTools.rightHotKeyCode,
            AppStorageKeys.WindowTools.rightHotKeyMods,
            AppStorageKeys.WindowTools.maximizeHotKeyCode,
            AppStorageKeys.WindowTools.maximizeHotKeyMods,
            AppStorageKeys.WindowTools.restoreHotKeyCode,
            AppStorageKeys.WindowTools.restoreHotKeyMods,
        ]
        let labelKeys = [
            AppStorageKeys.WindowTools.leftHotKeyLabel,
            AppStorageKeys.WindowTools.rightHotKeyLabel,
            AppStorageKeys.WindowTools.maximizeHotKeyLabel,
            AppStorageKeys.WindowTools.restoreHotKeyLabel,
        ]
        let greenButton = defaults.object(forKey: AppStorageKeys.WindowTools.greenButtonMaximizes)
        let configured =
            integerKeys.allSatisfy {
                defaults.object(forKey: $0) == nil || defaults.object(forKey: $0) is Int
            }
            && labelKeys.allSatisfy {
                defaults.object(forKey: $0) == nil || defaults.object(forKey: $0) is String
            }
            && (greenButton == nil || greenButton is Bool)
        return ExtensionAdapterFacts(
            configured: configured,
            readyDetail: "Window layouts and shortcuts are configured.",
            setupDetail: "A stored Window Tools shortcut is invalid."
        ).readiness
    }

    static func emojiReadiness(defaults: UserDefaults) -> ExtensionAdapterReadiness {
        let catalog = EmojiCatalog.shared
        guard !catalog.emoji.isEmpty else {
            return .failed("The bundled emoji catalog could not be read.")
        }
        let toneRaw = defaults.object(forKey: AppStorageKeys.Emoji.skinTone) as? Int
        let frequentCount = defaults.object(forKey: AppStorageKeys.Emoji.frequentCount) as? Int
        let configured =
            (toneRaw == nil || EmojiSkinTone(rawValue: toneRaw!) != nil)
            && (frequentCount == nil || (0...24).contains(frequentCount!))
        let ledger = EmojiUsageLedger.load(from: defaults, key: AppStorageKeys.Emoji.usage)
        return ExtensionAdapterFacts(
            configured: configured, contentCount: ledger.entries.count,
            readyDetail:
                "\(catalog.emoji.count) emoji available, \(ledger.entries.count) used recently.",
            setupDetail: "The stored skin tone or frequently used count is invalid.",
            emptyDetail: "\(catalog.emoji.count) emoji are ready and nothing has been used yet."
        ).readiness
    }

    private static func inputDeviceCount() -> Result<Int, ExtensionAdapterError> {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        let sizeStatus = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
        guard sizeStatus == noErr else {
            return .failure(.audio(sizeStatus))
        }
        var devices = [AudioDeviceID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let dataStatus = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices)
        guard dataStatus == noErr else {
            return .failure(.audio(dataStatus))
        }
        let count = devices.filter { device in
            var streams = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == noErr
                && streamSize > 0
        }.count
        return .success(count)
    }
}

enum ExtensionAdapterError: Error, Equatable, LocalizedError {
    case invalid(String)
    case audio(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .invalid(detail): detail
        case let .audio(status): "Core Audio device discovery failed with status \(status)."
        }
    }
}
