import Foundation

public enum VirtualCameraStore {
    public static var assetsDirectory: URL {
        DataRoot.virtualCamera.appendingPathComponent("assets")
    }

    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "webp",
    ]

    public static func load(_ defaults: UserDefaults = SharedDefaults.store) -> VirtualCameraState {
        decode(defaults.data(forKey: AppStorageKeys.VirtualCamera.state)) ?? VirtualCameraState()
    }

    public static func save(
        _ state: VirtualCameraState, to defaults: UserDefaults = SharedDefaults.store
    ) {
        guard let data = encode(state) else { return }
        defaults.set(data, forKey: AppStorageKeys.VirtualCamera.state)
    }

    public static func encode(_ state: VirtualCameraState) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(state.sanitized())
    }

    public static func decode(_ data: Data?) -> VirtualCameraState? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(VirtualCameraState.self, from: data)
    }

    public static func isEnabled(_ defaults: UserDefaults = SharedDefaults.store) -> Bool {
        defaults.bool(forKey: AppStorageKeys.VirtualCamera.enabled)
    }

    public static func announceChange(from origin: String) {
        IPC.post(IPC.Name.virtualCameraStateChanged, userInfo: [VirtualCameraIPC.originKey: origin])
    }

    public static func importAsset(
        from source: URL, directory: URL = assetsDirectory, fileManager: FileManager = .default
    ) throws -> URL {
        let ext = source.pathExtension.lowercased()
        guard imageExtensions.contains(ext) else {
            throw VirtualCameraRequestError.unsupportedImage(source.lastPathComponent)
        }
        guard fileManager.isReadableFile(atPath: source.path) else {
            throw VirtualCameraRequestError.missingFile(source.path)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString + "." + ext)
        try fileManager.copyItem(at: source, to: destination)
        return destination
    }

    public static func referencedAssets(in state: VirtualCameraState) -> Set<String> {
        let compositions = [state.composition] + state.scenes.map(\.composition)
        var paths = Set<String>()
        for composition in compositions {
            if let logo = composition.overlays.logo.imagePath { paths.insert(logo) }
            if let background = composition.background.imagePath { paths.insert(background) }
        }
        return paths
    }

    @discardableResult
    public static func pruneAssets(
        keeping state: VirtualCameraState, directory: URL = assetsDirectory,
        fileManager: FileManager = .default
    ) -> [URL] {
        let referenced = Set(
            referencedAssets(in: state).map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        guard
            let files = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        var removed: [URL] = []
        for file in files where !referenced.contains(file.standardizedFileURL.path) {
            if (try? fileManager.removeItem(at: file)) != nil { removed.append(file) }
        }
        return removed
    }
}
