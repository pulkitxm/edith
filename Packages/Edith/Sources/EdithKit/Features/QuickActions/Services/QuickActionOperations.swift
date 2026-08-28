import AppKit
import EdithCore
import Foundation
import Observation

public enum QuickAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case appearance
    case keyboardLight
    case emptyTrash
    case ejectDisks
    case hiddenFiles
    case desktopIcons
    case lockScreen

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .appearance: "Appearance"
        case .keyboardLight: "Keyboard light"
        case .emptyTrash: "Empty Trash"
        case .ejectDisks: "Eject disks"
        case .hiddenFiles: "Hidden files"
        case .desktopIcons: "Desktop icons"
        case .lockScreen: "Lock screen"
        }
    }

    public var symbolName: String {
        switch self {
        case .appearance: "circle.lefthalf.filled"
        case .keyboardLight: "keyboard"
        case .emptyTrash: "trash"
        case .ejectDisks: "eject.fill"
        case .hiddenFiles: "eye"
        case .desktopIcons: "desktopcomputer"
        case .lockScreen: "lock.fill"
        }
    }

    public var visibilityKey: String {
        switch self {
        case .appearance: AppStorageKeys.QuickActions.appearance
        case .keyboardLight: AppStorageKeys.QuickActions.keyboardLight
        case .emptyTrash: AppStorageKeys.QuickActions.emptyTrash
        case .ejectDisks: AppStorageKeys.QuickActions.ejectDisks
        case .hiddenFiles: AppStorageKeys.QuickActions.hiddenFiles
        case .desktopIcons: AppStorageKeys.QuickActions.desktopIcons
        case .lockScreen: AppStorageKeys.QuickActions.lockScreen
        }
    }

    public func stateLabel(in snapshot: QuickActionsSnapshot) -> String {
        switch self {
        case .appearance: return snapshot.appearance == .dark ? "Dark" : "Light"
        case .keyboardLight:
            guard snapshot.keyboardLightAvailable else { return "Unavailable" }
            return snapshot.keyboardLightEnabled == true ? "On" : "Off"
        case .emptyTrash: return "Confirmation required"
        case .ejectDisks:
            return snapshot.ejectableVolumes.isEmpty
                ? "No eligible disks"
                : "\(snapshot.ejectableVolumes.count) ready"
        case .hiddenFiles: return snapshot.hiddenFilesShown ? "Shown" : "Hidden"
        case .desktopIcons: return snapshot.desktopIconsShown ? "Shown" : "Hidden"
        case .lockScreen: return "Ready"
        }
    }

    public func isAvailable(in snapshot: QuickActionsSnapshot) -> Bool {
        switch self {
        case .keyboardLight: snapshot.keyboardLightAvailable
        default: true
        }
    }

    public var descriptor: UserOperationDescriptor {
        let effect: UserOperationEffect = self == .emptyTrash ? .destructive : .write
        return UserOperationDescriptor(
            id: UserOperationID(rawValue: "quick-actions.\(kebabName)"),
            summary: summary, cli: ["quick-actions", kebabName], effect: effect,
            requiresPreview: self == .emptyTrash)
    }

    private var kebabName: String {
        switch self {
        case .appearance: "appearance"
        case .keyboardLight: "keyboard-light"
        case .emptyTrash: "empty-trash"
        case .ejectDisks: "eject-disks"
        case .hiddenFiles: "hidden-files"
        case .desktopIcons: "desktop-icons"
        case .lockScreen: "lock-screen"
        }
    }

    private var summary: String {
        switch self {
        case .appearance: "Switch macOS between light and dark appearance."
        case .keyboardLight: "Turn the built-in keyboard backlight on or off."
        case .emptyTrash: "Permanently empty the current user's Trash."
        case .ejectDisks: "Safely eject every eligible external disk."
        case .hiddenFiles: "Show or hide hidden files in Finder."
        case .desktopIcons: "Show or hide Finder icons on the desktop."
        case .lockScreen: "Lock the current macOS session."
        }
    }
}

public enum QuickActionAppearance: String, Codable, Sendable {
    case light
    case dark
}

public struct QuickActionVolume: Codable, Equatable, Sendable {
    public let name: String
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

public enum QuickActionVolumePolicy {
    public static func shouldEject(
        isInternal: Bool?, isRemovable: Bool?, isEjectable: Bool?, isLocal: Bool?,
        isRootFileSystem: Bool, path: String
    ) -> Bool {
        let root = isRootFileSystem || path == "/"
        let external = isInternal == false || isRemovable == true || isEjectable == true
        return isLocal == true && !root && external
    }
}

public struct QuickActionsSnapshot: Codable, Equatable, Sendable {
    public let appearance: QuickActionAppearance
    public let keyboardLightAvailable: Bool
    public let keyboardLightEnabled: Bool?
    public let hiddenFilesShown: Bool
    public let desktopIconsShown: Bool
    public let ejectableVolumes: [QuickActionVolume]

    public init(
        appearance: QuickActionAppearance, keyboardLightAvailable: Bool,
        keyboardLightEnabled: Bool?, hiddenFilesShown: Bool, desktopIconsShown: Bool,
        ejectableVolumes: [QuickActionVolume]
    ) {
        self.appearance = appearance
        self.keyboardLightAvailable = keyboardLightAvailable
        self.keyboardLightEnabled = keyboardLightEnabled
        self.hiddenFilesShown = hiddenFilesShown
        self.desktopIconsShown = desktopIconsShown
        self.ejectableVolumes = ejectableVolumes
    }
}

public struct QuickActionResult: Codable, Equatable, Sendable {
    public let action: QuickAction
    public let changed: Bool
    public let affectedCount: Int
    public let message: String
    public let snapshot: QuickActionsSnapshot

    public init(
        action: QuickAction, changed: Bool, affectedCount: Int = 0, message: String,
        snapshot: QuickActionsSnapshot
    ) {
        self.action = action
        self.changed = changed
        self.affectedCount = affectedCount
        self.message = message
        self.snapshot = snapshot
    }
}

public enum QuickActionError: LocalizedError, Equatable {
    case unavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case let .unavailable(message), let .failed(message): message
        }
    }
}

public struct QuickActionEnvironment: @unchecked Sendable {
    public var appearance: () -> QuickActionAppearance
    public var toggleAppearance: () async throws -> Void
    public var keyboardLight: () -> Float?
    public var setKeyboardLight: (Float) -> Bool
    public var finderFlag: (String, Bool) -> Bool
    public var setFinderFlag: (String, Bool) async throws -> Void
    public var volumes: () -> [(url: URL, name: String)]
    public var eject: (URL) throws -> Void
    public var emptyTrash: () async throws -> Void
    public var lockScreen: () throws -> Void

    public init(
        appearance: @escaping () -> QuickActionAppearance,
        toggleAppearance: @escaping () async throws -> Void,
        keyboardLight: @escaping () -> Float?,
        setKeyboardLight: @escaping (Float) -> Bool,
        finderFlag: @escaping (String, Bool) -> Bool,
        setFinderFlag: @escaping (String, Bool) async throws -> Void,
        volumes: @escaping () -> [(url: URL, name: String)],
        eject: @escaping (URL) throws -> Void,
        emptyTrash: @escaping () async throws -> Void,
        lockScreen: @escaping () throws -> Void
    ) {
        self.appearance = appearance
        self.toggleAppearance = toggleAppearance
        self.keyboardLight = keyboardLight
        self.setKeyboardLight = setKeyboardLight
        self.finderFlag = finderFlag
        self.setFinderFlag = setFinderFlag
        self.volumes = volumes
        self.eject = eject
        self.emptyTrash = emptyTrash
        self.lockScreen = lockScreen
    }

    public static let live = QuickActionEnvironment(
        appearance: QuickActionSystem.appearance,
        toggleAppearance: QuickActionSystem.toggleAppearance,
        keyboardLight: QuickActionSystem.keyboardLight,
        setKeyboardLight: QuickActionSystem.setKeyboardLight,
        finderFlag: QuickActionSystem.finderFlag,
        setFinderFlag: QuickActionSystem.setFinderFlag,
        volumes: QuickActionSystem.ejectableVolumes,
        eject: { try NSWorkspace.shared.unmountAndEjectDevice(at: $0) },
        emptyTrash: QuickActionSystem.emptyTrash,
        lockScreen: QuickActionSystem.lockScreen)
}

public struct QuickActionCenter: @unchecked Sendable {
    public static let live = QuickActionCenter()

    public let environment: QuickActionEnvironment

    public init(environment: QuickActionEnvironment = .live) {
        self.environment = environment
    }

    public func snapshot() -> QuickActionsSnapshot {
        let keyboardLevel = environment.keyboardLight()
        return QuickActionsSnapshot(
            appearance: environment.appearance(), keyboardLightAvailable: keyboardLevel != nil,
            keyboardLightEnabled: keyboardLevel.map { $0 > 0 },
            hiddenFilesShown: environment.finderFlag("AppleShowAllFiles", false),
            desktopIconsShown: environment.finderFlag("CreateDesktop", true),
            ejectableVolumes: environment.volumes().map {
                QuickActionVolume(name: $0.name, path: $0.url.path)
            })
    }

    public func perform(_ action: QuickAction) async throws -> QuickActionResult {
        let before = snapshot()
        var affectedCount = 0
        switch action {
        case .appearance:
            try await environment.toggleAppearance()
        case .keyboardLight:
            guard let enabled = before.keyboardLightEnabled else {
                throw QuickActionError.unavailable(
                    "This Mac does not expose a controllable built-in keyboard backlight.")
            }
            guard environment.setKeyboardLight(enabled ? 0 : 0.5) else {
                throw QuickActionError.failed("The keyboard backlight did not accept the change.")
            }
        case .emptyTrash:
            try await environment.emptyTrash()
        case .ejectDisks:
            for volume in environment.volumes() {
                try environment.eject(volume.url)
                affectedCount += 1
            }
        case .hiddenFiles:
            try await environment.setFinderFlag("AppleShowAllFiles", !before.hiddenFilesShown)
        case .desktopIcons:
            try await environment.setFinderFlag("CreateDesktop", !before.desktopIconsShown)
        case .lockScreen:
            try environment.lockScreen()
        }
        let after = snapshot()
        return QuickActionResult(
            action: action,
            changed: changed(action, before: before, after: after, affectedCount: affectedCount),
            affectedCount: affectedCount,
            message: message(action, after: after, count: affectedCount),
            snapshot: after)
    }

    private func changed(
        _ action: QuickAction, before: QuickActionsSnapshot, after: QuickActionsSnapshot,
        affectedCount: Int
    ) -> Bool {
        switch action {
        case .appearance: before.appearance != after.appearance
        case .keyboardLight: before.keyboardLightEnabled != after.keyboardLightEnabled
        case .emptyTrash, .lockScreen: true
        case .ejectDisks: affectedCount > 0
        case .hiddenFiles: before.hiddenFilesShown != after.hiddenFilesShown
        case .desktopIcons: before.desktopIconsShown != after.desktopIconsShown
        }
    }

    private func message(_ action: QuickAction, after: QuickActionsSnapshot, count: Int) -> String {
        switch action {
        case .appearance: "Switched to \(after.appearance.rawValue) appearance."
        case .keyboardLight:
            after.keyboardLightEnabled == true
                ? "Turned the keyboard light on." : "Turned the keyboard light off."
        case .emptyTrash: "Emptied the Trash."
        case .ejectDisks:
            count == 0 ? "No eligible external disks are mounted." : "Ejected \(count) disks."
        case .hiddenFiles:
            after.hiddenFilesShown
                ? "Finder now shows hidden files." : "Finder now hides hidden files."
        case .desktopIcons:
            after.desktopIconsShown
                ? "Finder now shows desktop icons." : "Finder now hides desktop icons."
        case .lockScreen: "Locked the screen."
        }
    }
}

@MainActor
@Observable public final class QuickActionsModel {
    public private(set) var snapshot: QuickActionsSnapshot
    public private(set) var running: QuickAction?
    public private(set) var message: String?
    public private(set) var errorMessage: String?
    private let center: QuickActionCenter

    public init(center: QuickActionCenter = .live) {
        self.center = center
        snapshot = center.snapshot()
    }

    public func refresh() {
        snapshot = center.snapshot()
    }

    public func perform(_ action: QuickAction) {
        guard running == nil else { return }
        running = action
        message = nil
        errorMessage = nil
        let center = center
        Task {
            do {
                let value = try await center.perform(action)
                snapshot = value.snapshot
                message = value.message
            } catch {
                snapshot = center.snapshot()
                errorMessage = error.localizedDescription
            }
            running = nil
        }
    }
}

private enum QuickActionSystem {
    static let finderDomain = "com.apple.finder"
    static let keyboard = KeyboardLightBridge()

    static func appearance() -> QuickActionAppearance {
        let value = CFPreferencesCopyAppValue(
            "AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication)
        return (value as? String)?.lowercased() == "dark" ? .dark : .light
    }

    static func toggleAppearance() async throws {
        try await runAppleScript(
            "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
        )
    }

    static func keyboardLight() -> Float? {
        keyboard?.brightness()
    }

    static func setKeyboardLight(_ value: Float) -> Bool {
        keyboard?.setBrightness(value) ?? false
    }

    static func finderFlag(_ key: String, _ fallback: Bool) -> Bool {
        let value = CFPreferencesCopyAppValue(key as CFString, finderDomain as CFString)
        switch value {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.boolValue
        case let text as String:
            return ["yes", "true", "1"].contains(text.lowercased())
                ? true
                : (["no", "false", "0"].contains(text.lowercased()) ? false : fallback)
        default: return fallback
        }
    }

    static func setFinderFlag(_ key: String, _ value: Bool) async throws {
        CFPreferencesSetAppValue(key as CFString, value as CFBoolean, finderDomain as CFString)
        guard CFPreferencesAppSynchronize(finderDomain as CFString) else {
            throw QuickActionError.failed("Finder did not save the new preference.")
        }
        let result = try await runProcess("/usr/bin/killall", ["Finder"])
        if result.terminationStatus != 0 {
            let running = try await runProcess("/usr/bin/pgrep", ["-x", "Finder"])
            if running.terminationStatus == 0 {
                throw QuickActionError.failed("Finder could not restart.")
            }
        }
    }

    static func ejectableVolumes() -> [(url: URL, name: String)] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
            .volumeIsLocalKey, .volumeIsRootFileSystemKey,
        ]
        let urls =
            FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url -> (url: URL, name: String)? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            guard
                QuickActionVolumePolicy.shouldEject(
                    isInternal: values.volumeIsInternal, isRemovable: values.volumeIsRemovable,
                    isEjectable: values.volumeIsEjectable, isLocal: values.volumeIsLocal,
                    isRootFileSystem: values.volumeIsRootFileSystem ?? false, path: url.path)
            else { return nil }
            return (url, values.volumeName ?? url.lastPathComponent)
        }
    }

    static func emptyTrash() async throws {
        try await runAppleScript("tell application \"Finder\" to empty trash")
    }

    static func lockScreen() throws {
        if let lockScreenFunction {
            _ = lockScreenFunction()
            return
        }
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    static func runAppleScript(_ source: String) async throws {
        let result = try await runProcess("/usr/bin/osascript", ["-"], input: source)
        guard result.terminationStatus == 0 else {
            if result.output.contains("-1743")
                || result.output.lowercased().contains("not authorized")
            {
                throw QuickActionError.unavailable(
                    "Allow Automation access in System Settings, then try again.")
            }
            throw QuickActionError.failed(
                result.output.isEmpty ? "macOS refused the action." : result.output)
        }
    }

    static func runProcess(
        _ executable: String, _ arguments: [String], input: String? = nil
    ) async throws -> CLICommandResult {
        do {
            return try await CLICommandRunner.run(
                CLICommandRequest(
                    executableURL: URL(fileURLWithPath: executable), arguments: arguments,
                    environment: CLIToolEnvironment.sanitized(), timeout: 10,
                    maximumOutputBytes: 64 * 1_024,
                    standardInputData: input.map { Data($0.utf8) },
                    terminatesProcessGroup: true)
            ) { _ in }
        } catch {
            throw QuickActionError.failed("macOS action failed: \(error.localizedDescription)")
        }
    }

    private static let lockScreenFunction: (@convention(c) () -> Int32)? = {
        let path = "/System/Library/PrivateFrameworks/login.framework/login"
        guard let handle = dlopen(path, RTLD_LAZY),
            let symbol = dlsym(handle, "SACLockScreenImmediate")
        else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
    }()
}

private final class KeyboardLightBridge {
    private typealias CopyIDs = @convention(c) (NSObject, Selector) -> Unmanaged<AnyObject>
    private typealias IsBuiltIn = @convention(c) (NSObject, Selector, UInt64) -> ObjCBool
    private typealias GetBrightness = @convention(c) (NSObject, Selector, UInt64) -> Float
    private typealias SetBrightness =
        @convention(c) (NSObject, Selector, Float, Int32, Bool, UInt64) -> ObjCBool
    private typealias SuspendIdleDimming =
        @convention(c) (NSObject, Selector, Bool, UInt64) -> ObjCBool

    private let client: NSObject
    private let keyboardID: UInt64
    private let getBrightness: GetBrightness
    private let setBrightnessValue: SetBrightness
    private let suspendIdleDimming: SuspendIdleDimming
    private let getSelector = NSSelectorFromString("brightnessForKeyboard:")
    private let setSelector = NSSelectorFromString("setBrightness:fadeSpeed:commit:forKeyboard:")
    private let suspendSelector = NSSelectorFromString("suspendIdleDimming:forKeyboard:")

    init?() {
        guard
            let framework = Bundle(
                path: "/System/Library/PrivateFrameworks/CoreBrightness.framework"),
            framework.load(),
            let clientClass = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type
        else { return nil }
        let client = clientClass.init()
        let copySelector = NSSelectorFromString("copyKeyboardBacklightIDs")
        let builtInSelector = NSSelectorFromString("isKeyboardBuiltIn:")
        guard let copyIDs: CopyIDs = Self.implementation(client, copySelector, CopyIDs.self),
            let isBuiltIn: IsBuiltIn = Self.implementation(client, builtInSelector, IsBuiltIn.self),
            let getBrightness: GetBrightness = Self.implementation(
                client, getSelector, GetBrightness.self),
            let setBrightness: SetBrightness = Self.implementation(
                client, setSelector, SetBrightness.self),
            let suspendIdleDimming: SuspendIdleDimming = Self.implementation(
                client, suspendSelector, SuspendIdleDimming.self),
            let ids = copyIDs(client, copySelector).takeRetainedValue() as? [NSNumber],
            let keyboardID = ids.map(\.uint64Value).first(where: {
                isBuiltIn(client, builtInSelector, $0).boolValue
            })
        else { return nil }
        self.client = client
        self.keyboardID = keyboardID
        self.getBrightness = getBrightness
        setBrightnessValue = setBrightness
        self.suspendIdleDimming = suspendIdleDimming
    }

    func brightness() -> Float {
        getBrightness(client, getSelector, keyboardID)
    }

    func setBrightness(_ value: Float) -> Bool {
        _ = suspendIdleDimming(client, suspendSelector, true, keyboardID)
        defer { _ = suspendIdleDimming(client, suspendSelector, false, keyboardID) }
        return setBrightnessValue(
            client, setSelector, min(max(value, 0), 1), 350, true, keyboardID
        ).boolValue
    }

    private static func implementation<T>(
        _ object: NSObject, _ selector: Selector, _ type: T.Type
    ) -> T? {
        guard object.responds(to: selector),
            let method = class_getInstanceMethod(Swift.type(of: object), selector)
        else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: type)
    }
}
