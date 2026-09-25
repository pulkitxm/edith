import Foundation

public enum VirtualCameraPrivacy: String, Codable, CaseIterable, Sendable {
    case live
    case card
    case blank
    case freeze

    public var title: String {
        switch self {
        case .live: "Live"
        case .card: "Be right back"
        case .blank: "Blank"
        case .freeze: "Freeze"
        }
    }

    public var usesCamera: Bool { self == .live }
}

public enum VirtualCameraTransition: String, Codable, CaseIterable, Sendable {
    case cut
    case smooth

    public var title: String {
        switch self {
        case .cut: "Cut"
        case .smooth: "Smooth"
        }
    }

    public var duration: TimeInterval {
        switch self {
        case .cut: 0
        case .smooth: 0.45
        }
    }
}

public struct VirtualCameraScene: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var composition: VirtualCameraComposition
    public var sourceID: String?

    public static let maximumNameLength = 40

    public init(
        id: UUID = UUID(), name: String, composition: VirtualCameraComposition,
        sourceID: String? = nil
    ) {
        self.id = id
        self.name = String(name.prefix(Self.maximumNameLength))
        self.composition = composition
        self.sourceID = sourceID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            composition: (try? container.decodeIfPresent(
                VirtualCameraComposition.self, forKey: .composition)) ?? VirtualCameraComposition(),
            sourceID: try? container.decodeIfPresent(String.self, forKey: .sourceID))
    }
}

public struct VirtualCameraState: Codable, Equatable, Sendable {
    public static let defaultPrivacyMessage = "Be right back"
    public static let maximumMessageLength = 80
    public static let maximumScenes = 24

    public var sourceID: String?
    public var composition: VirtualCameraComposition
    public var scenes: [VirtualCameraScene]
    public var activeSceneID: UUID?
    public var privacy: VirtualCameraPrivacy
    public var privacyMessage: String
    public var transition: VirtualCameraTransition
    public var sharpZoom: Bool
    public var mirrorPreview: Bool

    public init(
        sourceID: String? = nil, composition: VirtualCameraComposition = VirtualCameraComposition(),
        scenes: [VirtualCameraScene] = VirtualCameraState.starterScenes(),
        activeSceneID: UUID? = nil, privacy: VirtualCameraPrivacy = .live,
        privacyMessage: String = VirtualCameraState.defaultPrivacyMessage,
        transition: VirtualCameraTransition = .smooth, sharpZoom: Bool = true,
        mirrorPreview: Bool = true
    ) {
        self.sourceID = sourceID
        self.composition = composition
        self.scenes = scenes
        self.activeSceneID = activeSceneID
        self.privacy = privacy
        self.privacyMessage = privacyMessage
        self.transition = transition
        self.sharpZoom = sharpZoom
        self.mirrorPreview = mirrorPreview
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = VirtualCameraState()
        self.init(
            sourceID: try? container.decodeIfPresent(String.self, forKey: .sourceID),
            composition: (try? container.decodeIfPresent(
                VirtualCameraComposition.self, forKey: .composition)) ?? fallback.composition,
            scenes: (try? container.decodeIfPresent([VirtualCameraScene].self, forKey: .scenes))
                ?? fallback.scenes,
            activeSceneID: try? container.decodeIfPresent(UUID.self, forKey: .activeSceneID),
            privacy: (try? container.decodeIfPresent(VirtualCameraPrivacy.self, forKey: .privacy))
                ?? fallback.privacy,
            privacyMessage: (try? container.decodeIfPresent(String.self, forKey: .privacyMessage))
                ?? fallback.privacyMessage,
            transition: (try? container.decodeIfPresent(
                VirtualCameraTransition.self, forKey: .transition)) ?? fallback.transition,
            sharpZoom: (try? container.decodeIfPresent(Bool.self, forKey: .sharpZoom))
                ?? fallback.sharpZoom,
            mirrorPreview: (try? container.decodeIfPresent(Bool.self, forKey: .mirrorPreview))
                ?? fallback.mirrorPreview)
        self = sanitized()
    }

    public func sanitized() -> VirtualCameraState {
        var copy = self
        copy.composition = composition.sanitized()
        var seenIDs = Set<UUID>()
        var seenNames = Set<String>()
        copy.scenes = scenes.compactMap { scene in
            let name = scene.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seenIDs.insert(scene.id).inserted,
                seenNames.insert(name.lowercased()).inserted
            else { return nil }
            var cleaned = scene
            cleaned.name = name
            cleaned.composition = scene.composition.sanitized()
            return cleaned
        }
        if copy.scenes.count > Self.maximumScenes {
            copy.scenes = Array(copy.scenes.prefix(Self.maximumScenes))
        }
        if let active = activeSceneID, !copy.scenes.contains(where: { $0.id == active }) {
            copy.activeSceneID = nil
        }
        let message = privacyMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.privacyMessage =
            message.isEmpty
            ? Self.defaultPrivacyMessage : String(message.prefix(Self.maximumMessageLength))
        if let source = sourceID, source.isEmpty { copy.sourceID = nil }
        return copy
    }

    public var activeScene: VirtualCameraScene? {
        guard let activeSceneID else { return nil }
        return scenes.first { $0.id == activeSceneID }
    }

    public var activeSceneIsModified: Bool {
        guard let scene = activeScene else { return false }
        return scene.composition != composition
    }

    public static func starterScenes() -> [VirtualCameraScene] {
        [
            VirtualCameraScene(
                id: UUID(uuidString: "6E3C1F2A-5B4D-4E8F-9A10-000000000001") ?? UUID(),
                name: "Full frame", composition: VirtualCameraComposition()),
            VirtualCameraScene(
                id: UUID(uuidString: "6E3C1F2A-5B4D-4E8F-9A10-000000000002") ?? UUID(),
                name: "Close-up",
                composition: VirtualCameraComposition(
                    framing: VirtualCameraFraming(zoom: 1.6, centerY: 0.42))),
        ]
    }
}
