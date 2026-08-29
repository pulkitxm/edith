import Foundation

public enum DockPreviewMode: String, CaseIterable, Codable, Sendable {
    case hover
    case optionClick

    public var title: String {
        switch self {
        case .hover: "Hover"
        case .optionClick: "Option-click"
        }
    }
}

public enum DockClickAction: String, CaseIterable, Codable, Sendable {
    case standard
    case cycleWindows
    case minimizeFrontWindow

    public var title: String {
        switch self {
        case .standard: "Standard"
        case .cycleWindows: "Cycle windows"
        case .minimizeFrontWindow: "Minimize front window"
        }
    }
}

public struct DockToolsPreferences: Equatable, Sendable {
    public static let hoverDelayRange = 0.15...1.0
    public static let defaultHoverDelay = 0.3

    public let enabled: Bool
    public let previewMode: DockPreviewMode
    public let hoverDelay: Double
    public let clickAction: DockClickAction
    public let greenButtonMaximizes: Bool
    public let quitOnLastWindow: Bool
    public let excludedBundleIdentifiers: Set<String>

    public init(
        enabled: Bool, previewMode: DockPreviewMode, hoverDelay: Double,
        clickAction: DockClickAction, greenButtonMaximizes: Bool,
        quitOnLastWindow: Bool, excludedBundleIdentifiers: Set<String>
    ) {
        self.enabled = enabled
        self.previewMode = previewMode
        self.hoverDelay = Self.sanitizedHoverDelay(hoverDelay)
        self.clickAction = clickAction
        self.greenButtonMaximizes = greenButtonMaximizes
        self.quitOnLastWindow = quitOnLastWindow
        self.excludedBundleIdentifiers = Set(
            excludedBundleIdentifiers.map { $0.lowercased() })
    }

    public init(defaults: UserDefaults = SharedDefaults.store) {
        let previewMode =
            defaults.string(forKey: AppStorageKeys.DockTools.previewMode)
            .flatMap(DockPreviewMode.init(rawValue:)) ?? .hover
        let clickAction =
            defaults.string(forKey: AppStorageKeys.DockTools.clickAction)
            .flatMap(DockClickAction.init(rawValue:)) ?? .standard
        let delay =
            defaults.object(forKey: AppStorageKeys.DockTools.hoverDelay) as? Double
            ?? Self.defaultHoverDelay
        self.init(
            enabled: defaults.bool(forKey: AppStorageKeys.DockTools.enabled),
            previewMode: previewMode, hoverDelay: delay, clickAction: clickAction,
            greenButtonMaximizes: defaults.bool(
                forKey: AppStorageKeys.DockTools.greenButtonMaximizes),
            quitOnLastWindow: defaults.bool(forKey: AppStorageKeys.DockTools.quitOnLastWindow),
            excludedBundleIdentifiers: Self.identifiers(
                defaults.string(forKey: AppStorageKeys.DockTools.excludedApps) ?? ""))
    }

    public func excludes(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return excludedBundleIdentifiers.contains(bundleIdentifier.lowercased())
    }

    public static func sanitizedHoverDelay(_ value: Double) -> Double {
        guard value.isFinite else { return defaultHoverDelay }
        return min(max(value, hoverDelayRange.lowerBound), hoverDelayRange.upperBound)
    }

    public static func identifiers(_ value: String) -> Set<String> {
        Set(
            value.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty })
    }

    public static func encodedIdentifiers(_ values: some Sequence<String>) -> String {
        Set(values.map { $0.lowercased() }).sorted().joined(separator: ",")
    }
}

public struct DockToolsWindow: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let appName: String
    public let bundleIdentifier: String
    public let pid: Int32
    public let minimized: Bool

    public init(
        id: String, title: String, appName: String, bundleIdentifier: String,
        pid: Int32, minimized: Bool
    ) {
        self.id = id
        self.title = title
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.pid = pid
        self.minimized = minimized
    }

    public var displayTitle: String {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? appName : value
    }
}

public struct DockToolsStatus: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let helperRunning: Bool
    public let accessibilityGranted: Bool
    public let screenRecordingGranted: Bool
    public let previewMode: DockPreviewMode
    public let clickAction: DockClickAction
    public let greenButtonMaximizes: Bool
    public let quitOnLastWindow: Bool
    public let excludedApps: [String]

    public init(
        preferences: DockToolsPreferences, helperRunning: Bool,
        accessibilityGranted: Bool, screenRecordingGranted: Bool
    ) {
        enabled = preferences.enabled
        self.helperRunning = helperRunning
        self.accessibilityGranted = accessibilityGranted
        self.screenRecordingGranted = screenRecordingGranted
        previewMode = preferences.previewMode
        clickAction = preferences.clickAction
        greenButtonMaximizes = preferences.greenButtonMaximizes
        quitOnLastWindow = preferences.quitOnLastWindow
        excludedApps = preferences.excludedBundleIdentifiers.sorted()
    }

    public var ready: Bool { enabled && helperRunning && accessibilityGranted }
    public var previewsAvailable: Bool { ready && screenRecordingGranted }
}

public enum DockToolsPolicy {
    public static func shouldHandleDockClick(
        action: DockClickAction, appIsFrontmost: Bool, excluded: Bool
    ) -> Bool {
        action != .standard && appIsFrontmost && !excluded
    }

    public static func shouldQuit(
        enabled: Bool, hadWindows: Bool, hasWindows: Bool, excluded: Bool,
        terminated: Bool, regularApplication: Bool
    ) -> Bool {
        enabled && hadWindows && !hasWindows && !excluded && !terminated && regularApplication
    }

    public static func adjacentIndex(current: Int?, count: Int, offset: Int) -> Int? {
        guard count > 0 else { return nil }
        return ((current ?? (offset > 0 ? -1 : 0)) + offset + count) % count
    }
}

public enum DockToolsIPC {
    public static let requestIDKey = "requestID"
    public static let operationKey = "operation"
    public static let bundleIdentifierKey = "bundleIdentifier"
    public static let statusKey = "status"
    public static let payloadKey = "payload"

    public static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from value: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(value.utf8))
    }
}
