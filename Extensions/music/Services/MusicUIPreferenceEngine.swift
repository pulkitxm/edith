import EdithExtensionSupport
import Foundation
#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif

@MainActor struct MusicUIPreferenceEngine {
    private let object: (String) -> Any?
    private let boolean: (String) -> Bool
    private let set: (Any, String) -> Void

    init(defaults: UserDefaults) {
        object = defaults.object(forKey:)
        boolean = defaults.bool(forKey:)
        set = defaults.set(_:forKey:)
    }

    init(
        object: @escaping (String) -> Any?, boolean: @escaping (String) -> Bool,
        set: @escaping (Any, String) -> Void
    ) {
        self.object = object; self.boolean = boolean; self.set = set
    }

    static func invalidateHostSlots() {
        guard let namespace = ExtensionSharedState.current?.namespace else { return }
        DistributedNotificationCenter.default().postNotificationName(
            .init(namespace + ".musicHostSlots"), object: nil, userInfo: nil,
            deliverImmediately: true)
    }

    static func accepts(_ kind: MusicUIActionKind) -> Bool {
        [.crossfade, .barCollapsed, .barAutoHide, .gridView, .fadeLength].contains(kind)
    }

    func perform(_ action: MusicUIAction, invalidateHostSlots: () -> Void) throws {
        try action.validate()
        switch action.kind {
        case .crossfade, .barCollapsed, .barAutoHide, .gridView:
            guard let value = action.value, (0...1).contains(value), value == 0 || value == 1
            else { throw ExtensionPeerError.invalidRequest }
            let key: String
            switch action.kind {
            case .crossfade: key = MusicFade.enabledKey
            case .barCollapsed: key = AppStorageKeys.Music.barCollapsed
            case .barAutoHide: key = AppStorageKeys.Music.barAutoHide
            default: key = AppStorageKeys.Music.gridView
            }
            let changed = object(key) as? Bool != (value == 1)
            set(value == 1, key)
            if changed, [.barCollapsed, .barAutoHide].contains(action.kind) {
                invalidateHostSlots()
            }
        case .fadeLength:
            guard let value = action.value, MusicFade.secondsRange.contains(value) else {
                throw ExtensionPeerError.invalidRequest
            }
            set(value, MusicFade.secondsKey)
        default: throw ExtensionPeerError.invalidRequest
        }
    }

    #if canImport(WorkerFixtureSupport)
    func executeFixture(
        _ operation: String, payload: Data, version: String,
        requireCurrent: () throws -> Void, invalidateHostSlots: () -> Void
    ) throws -> Data {
        let object = try WorkerFixtureJSON.object(payload, maximumBytes: 16_384)
        try Task.checkCancellation()
        if operation == "music.ui.settings" {
            guard payload.count <= 256, object.isEmpty, !version.isEmpty,
                version.utf8.count <= 128, !version.utf8.contains(0)
            else { throw ExtensionPeerError.invalidRequest }
            try requireCurrent()
            return try JSONEncoder().encode(
                MusicUISettings(version: version, preferences: preferences()))
        }
        guard operation == "music.ui.action",
            Set(object.keys) == ["kind", "path", "target", "value"]
        else { throw ExtensionPeerError.invalidRequest }
        let action = try JSONDecoder().decode(MusicUIAction.self, from: payload)
        guard action.path.isEmpty, action.target.isEmpty,
            [.crossfade, .fadeLength, .barCollapsed, .barAutoHide].contains(action.kind)
        else { throw ExtensionPeerError.invalidRequest }
        try requireCurrent()
        try perform(action, invalidateHostSlots: invalidateHostSlots)
        return Data("{}".utf8)
    }
    #endif

    func preferences() -> MusicUIPreferences {
        let seconds = object(MusicFade.secondsKey) as? Double ?? MusicFade.defaultSeconds
        return MusicUIPreferences(
            crossfade: object(MusicFade.enabledKey) as? Bool ?? true,
            fadeLength: seconds.isFinite
                ? min(
                    max(seconds, MusicFade.secondsRange.lowerBound),
                    MusicFade.secondsRange.upperBound)
                : MusicFade.defaultSeconds,
            barCollapsed: boolean(AppStorageKeys.Music.barCollapsed),
            barAutoHide: boolean(AppStorageKeys.Music.barAutoHide),
            gridView: boolean(AppStorageKeys.Music.gridView))
    }
}
