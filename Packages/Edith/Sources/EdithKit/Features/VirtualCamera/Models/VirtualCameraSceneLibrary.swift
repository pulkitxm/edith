import Foundation

public enum VirtualCameraSceneError: LocalizedError, Equatable, Sendable {
    case emptyName
    case duplicateName(String)
    case notFound(String)
    case limitReached(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyName: "A scene needs a name."
        case .duplicateName(let name): "A scene named \(name) already exists."
        case .notFound(let name): "No scene matches \(name)."
        case .limitReached(let limit): "Edith keeps up to \(limit) scenes. Delete one first."
        }
    }
}

public enum VirtualCameraSceneLibrary {
    public static func find(_ query: String, in scenes: [VirtualCameraScene])
        -> VirtualCameraScene?
    {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let id = UUID(uuidString: trimmed), let scene = scenes.first(where: { $0.id == id }) {
            return scene
        }
        if let exact = scenes.first(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return exact
        }
        if let number = Int(trimmed), scenes.indices.contains(number - 1) {
            return scenes[number - 1]
        }
        let prefixed = scenes.filter { $0.name.lowercased().hasPrefix(trimmed.lowercased()) }
        return prefixed.count == 1 ? prefixed[0] : nil
    }

    public static func uniqueName(_ base: String, in scenes: [VirtualCameraScene]) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let root =
            trimmed.isEmpty
            ? "Scene" : String(trimmed.prefix(VirtualCameraScene.maximumNameLength - 4))
        let taken = Set(scenes.map { $0.name.lowercased() })
        guard taken.contains(root.lowercased()) else { return root }
        var index = 2
        while taken.contains("\(root) \(index)".lowercased()) { index += 1 }
        return "\(root) \(index)"
    }

    public static func save(
        _ name: String, in state: inout VirtualCameraState, replacing: Bool = false
    ) throws -> VirtualCameraScene {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VirtualCameraSceneError.emptyName }
        if let index = state.scenes.firstIndex(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            guard replacing else { throw VirtualCameraSceneError.duplicateName(trimmed) }
            state.scenes[index].composition = state.composition
            state.scenes[index].sourceID = state.sourceID
            state.activeSceneID = state.scenes[index].id
            return state.scenes[index]
        }
        guard state.scenes.count < VirtualCameraState.maximumScenes else {
            throw VirtualCameraSceneError.limitReached(VirtualCameraState.maximumScenes)
        }
        let scene = VirtualCameraScene(
            name: trimmed, composition: state.composition, sourceID: state.sourceID)
        state.scenes.append(scene)
        state.activeSceneID = scene.id
        return scene
    }

    public static func update(_ id: UUID, in state: inout VirtualCameraState) throws {
        guard let index = state.scenes.firstIndex(where: { $0.id == id }) else {
            throw VirtualCameraSceneError.notFound(id.uuidString)
        }
        state.scenes[index].composition = state.composition
        state.scenes[index].sourceID = state.sourceID
        state.activeSceneID = id
    }

    @discardableResult
    public static func apply(_ query: String, in state: inout VirtualCameraState) throws
        -> VirtualCameraScene
    {
        guard let scene = find(query, in: state.scenes) else {
            throw VirtualCameraSceneError.notFound(query)
        }
        state.composition = scene.composition
        if let source = scene.sourceID { state.sourceID = source }
        state.activeSceneID = scene.id
        return scene
    }

    public static func rename(
        _ id: UUID, to name: String, in state: inout VirtualCameraState
    ) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VirtualCameraSceneError.emptyName }
        guard let index = state.scenes.firstIndex(where: { $0.id == id }) else {
            throw VirtualCameraSceneError.notFound(id.uuidString)
        }
        if state.scenes.contains(where: {
            $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            throw VirtualCameraSceneError.duplicateName(trimmed)
        }
        state.scenes[index].name = String(trimmed.prefix(VirtualCameraScene.maximumNameLength))
    }

    public static func duplicate(_ id: UUID, in state: inout VirtualCameraState) throws
        -> VirtualCameraScene
    {
        guard let original = state.scenes.first(where: { $0.id == id }) else {
            throw VirtualCameraSceneError.notFound(id.uuidString)
        }
        guard state.scenes.count < VirtualCameraState.maximumScenes else {
            throw VirtualCameraSceneError.limitReached(VirtualCameraState.maximumScenes)
        }
        let copy = VirtualCameraScene(
            name: uniqueName(original.name, in: state.scenes), composition: original.composition,
            sourceID: original.sourceID)
        if let index = state.scenes.firstIndex(where: { $0.id == id }) {
            state.scenes.insert(copy, at: index + 1)
        } else {
            state.scenes.append(copy)
        }
        return copy
    }

    public static func delete(_ id: UUID, in state: inout VirtualCameraState) throws {
        guard let index = state.scenes.firstIndex(where: { $0.id == id }) else {
            throw VirtualCameraSceneError.notFound(id.uuidString)
        }
        state.scenes.remove(at: index)
        if state.activeSceneID == id { state.activeSceneID = nil }
    }

    public static func move(_ id: UUID, by offset: Int, in state: inout VirtualCameraState) {
        guard let index = state.scenes.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(index + offset, 0), state.scenes.count - 1)
        guard target != index else { return }
        let scene = state.scenes.remove(at: index)
        state.scenes.insert(scene, at: target)
    }

    public static func step(_ offset: Int, in state: inout VirtualCameraState)
        -> VirtualCameraScene?
    {
        guard !state.scenes.isEmpty else { return nil }
        let current = state.activeSceneID.flatMap { id in
            state.scenes.firstIndex { $0.id == id }
        }
        let count = state.scenes.count
        let next =
            current.map { (($0 + offset) % count + count) % count } ?? (offset >= 0 ? 0 : count - 1)
        let scene = state.scenes[next]
        state.composition = scene.composition
        if let source = scene.sourceID { state.sourceID = source }
        state.activeSceneID = scene.id
        return scene
    }
}
