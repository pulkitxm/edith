import Foundation

public struct HerdrTerminalSettings: Equatable, Sendable {
    public enum StartFolder: String, CaseIterable, Sendable {
        case agent
        case home

        public var title: String {
            switch self {
            case .agent: "Agent's folder"
            case .home: "Home folder"
            }
        }
    }

    public static let fontSizeDefault = 13.0
    public static let fontSizeRange = 9.0...24.0

    public var mouse: HerdrTerminalMouse
    public var fontSize: Double
    public var startFolder: StartFolder
    public var startupCommand: String
    public var confirmClose: Bool

    public init(
        mouse: HerdrTerminalMouse = .scroll, fontSize: Double = fontSizeDefault,
        startFolder: StartFolder = .agent, startupCommand: String = "", confirmClose: Bool = true
    ) {
        self.mouse = mouse
        self.fontSize = fontSize
        self.startFolder = startFolder
        self.startupCommand = startupCommand
        self.confirmClose = confirmClose
    }

    public static func load(_ defaults: UserDefaults = SharedDefaults.store) -> Self {
        let size = defaults.object(forKey: AppStorageKeys.Herdr.terminalFontSize) as? Double
        return HerdrTerminalSettings(
            mouse: defaults.string(forKey: AppStorageKeys.Herdr.terminalMouse)
                .flatMap(HerdrTerminalMouse.init(rawValue:)) ?? .scroll,
            fontSize: clampedFontSize(size ?? fontSizeDefault),
            startFolder: defaults.string(forKey: AppStorageKeys.Herdr.terminalStartFolder)
                .flatMap(StartFolder.init(rawValue:)) ?? .agent,
            startupCommand: defaults.string(forKey: AppStorageKeys.Herdr.terminalStartupCommand)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            confirmClose: defaults.object(forKey: AppStorageKeys.Herdr.terminalConfirmClose)
                as? Bool ?? true)
    }

    public static func clampedFontSize(_ size: Double) -> Double {
        min(fontSizeRange.upperBound, max(fontSizeRange.lowerBound, size.rounded()))
    }
}
