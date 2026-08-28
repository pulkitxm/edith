import Carbon.HIToolbox
import EdithCore
import Foundation

public enum RadialLauncherItemKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case application
    case file
    case link
    case keyCombination
    case media
    case edith

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .application: "Application"
        case .file: "File or folder"
        case .link: "Link"
        case .keyCombination: "Key combination"
        case .media: "Media control"
        case .edith: "Edith action"
        }
    }

    public var defaultSymbol: String {
        switch self {
        case .application: "app.fill"
        case .file: "folder.fill"
        case .link: "link"
        case .keyCombination: "command"
        case .media: "playpause.fill"
        case .edith: "sparkles"
        }
    }
}

public enum RadialLauncherMediaAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case playPause
    case next
    case previous

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .playPause: "Play or pause"
        case .next: "Next track"
        case .previous: "Previous track"
        }
    }

    public var symbol: String {
        switch self {
        case .playPause: "playpause.fill"
        case .next: "forward.fill"
        case .previous: "backward.fill"
        }
    }
}

public enum RadialLauncherEdithAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case openPanel
    case clipboard
    case colorPicker
    case micMute
    case cleanKeys

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .openPanel: "Open Edith panel"
        case .clipboard: "Open clipboard"
        case .colorPicker: "Pick a color"
        case .micMute: "Toggle mic mute"
        case .cleanKeys: "Clean keyboard"
        }
    }

    public var symbol: String {
        switch self {
        case .openPanel: "eyeglasses"
        case .clipboard: "doc.on.clipboard"
        case .colorPicker: "eyedropper"
        case .micMute: "mic.slash.fill"
        case .cleanKeys: "keyboard"
        }
    }
}

public struct RadialLauncherItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: RadialLauncherItemKind
    public var name: String
    public var symbol: String
    public var payload: String
    public var keyCode: Int
    public var modifiers: Int

    public init(
        id: UUID = UUID(), kind: RadialLauncherItemKind, name: String, symbol: String = "",
        payload: String = "", keyCode: Int = 0, modifiers: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.symbol = symbol
        self.payload = payload
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var effectiveSymbol: String {
        if !symbol.isEmpty { return symbol }
        if kind == .media, let action = RadialLauncherMediaAction(rawValue: payload) {
            return action.symbol
        }
        if kind == .edith, let action = RadialLauncherEdithAction(rawValue: payload) {
            return action.symbol
        }
        return kind.defaultSymbol
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.title : trimmed
    }

    public var isConfigured: Bool {
        switch kind {
        case .application, .file:
            return !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .link:
            guard let url = URL(string: payload), let scheme = url.scheme?.lowercased() else {
                return false
            }
            return scheme == "http" || scheme == "https"
        case .keyCombination:
            return modifiers != 0 && !payload.isEmpty
        case .media:
            return RadialLauncherMediaAction(rawValue: payload) != nil
        case .edith:
            return RadialLauncherEdithAction(rawValue: payload) != nil
        }
    }
}

public struct RadialLauncherProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var items: [RadialLauncherItem]

    public init(id: UUID = UUID(), name: String, items: [RadialLauncherItem]) {
        self.id = id
        self.name = name
        self.items = Array(items.prefix(8))
    }

    public static var starter: Self {
        RadialLauncherProfile(
            name: "Favorites",
            items: [
                RadialLauncherItem(
                    kind: .application, name: "Safari",
                    payload: "/System/Applications/Safari.app"),
                RadialLauncherItem(
                    kind: .file, name: "Downloads", payload: "~/Downloads"),
                RadialLauncherItem(
                    kind: .link, name: "Edith",
                    payload: "https://github.com/pulkitxm/edith"),
                RadialLauncherItem(
                    kind: .keyCombination, name: "Screenshot", symbol: "camera.viewfinder",
                    payload: "⇧⌘4", keyCode: kVK_ANSI_4, modifiers: cmdKey | shiftKey),
                RadialLauncherItem(
                    kind: .media, name: "Play or pause",
                    payload: RadialLauncherMediaAction.playPause.rawValue),
                RadialLauncherItem(
                    kind: .edith, name: "Edith panel",
                    payload: RadialLauncherEdithAction.openPanel.rawValue),
            ])
    }
}

public enum RadialLauncherSelection {
    public static func index(
        dx: Double, dy: Double, itemCount: Int, deadZone: Double
    ) -> Int? {
        guard itemCount > 0, hypot(dx, dy) >= deadZone else { return nil }
        let step = 2 * Double.pi / Double(itemCount)
        var index = Int(round((Double.pi / 2 - atan2(dy, dx)) / step)) % itemCount
        if index < 0 { index += itemCount }
        return index
    }
}

public enum RadialLauncherProfileStore {
    public static func decode(_ value: String?) -> RadialLauncherProfile {
        guard let value, let profile = decodeIfValid(value) else { return .starter }
        return profile
    }

    public static func decodeIfValid(_ value: String) -> RadialLauncherProfile? {
        guard let data = value.data(using: .utf8),
            let profile = try? JSONDecoder().decode(RadialLauncherProfile.self, from: data)
        else { return nil }
        return RadialLauncherProfile(id: profile.id, name: profile.name, items: profile.items)
    }

    public static func encode(_ profile: RadialLauncherProfile) -> String {
        guard let data = try? JSONEncoder().encode(profile) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum RadialLauncherOperation: String, CaseIterable, Sendable {
    case show
    case profile

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .show:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "radial.show"),
                summary: "Show the Radial Launcher at the pointer.",
                cli: ["radial", "show"], effect: .interactive)
        case .profile:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "radial.profile"),
                summary: "Read the active Radial Launcher profile.",
                cli: ["radial", "profile"], effect: .read)
        }
    }
}
