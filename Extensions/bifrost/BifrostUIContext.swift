import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Observation

struct BifrostUISettings: Codable {
    let values: [String: String]
    let index: BifrostIndex?
}
struct BifrostUIChange: Codable { let key: String; let value: String }

@MainActor @Observable final class BifrostUIContext {
    static var current: BifrostUIContext?
    private(set) var index: BifrostIndex?
    private(set) var loaded = false
    private(set) var error: String?
    private let invoke: (String, Data) async throws -> Data
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var stopped = false
    private var applying = false
    private var observer: NSObjectProtocol?
    private var previous: [String: String] = [:]

    static let boolKeys =
        [AppStorageKeys.Bifrost.enabled, AppStorageKeys.Bifrost.pasteSnippets]
        + BifrostSource.allCases.map(\.defaultsKey)
    static let intKeys = [
        AppStorageKeys.Bifrost.resultLimit, "bifrostHotKeyCode", "bifrostHotKeyModifiers",
    ]
    static let stringKeys = [
        AppStorageKeys.Bifrost.popupAt, AppStorageKeys.Bifrost.quicklinks,
        AppStorageKeys.Bifrost.snippets, AppStorageKeys.Bifrost.shellCommands,
    ]
    static var keys: [String] { boolKeys + intKeys + stringKeys }

    convenience init(client: ExtensionEngineClient) {
        self.init(invoke: { try await client.invoke($0, payload: $1) })
    }
    init(invoke: @escaping (String, Data) async throws -> Data) {
        self.invoke = invoke
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: SharedDefaults.store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.settingsChanged() }
        }
    }

    func load() async {
        guard !stopped else { return }
        do {
            let data = try await invoke("bifrost.ui.settings", Data("{}".utf8))
            let value = try JSONDecoder().decode(BifrostUISettings.self, from: data)
            guard !stopped, !Task.isCancelled else { return }
            applying = true
            defer { applying = false }
            for (key, text) in value.values { try Self.set(key, value: text) }
            previous = value.values; index = value.index; loaded = true
            applying = false
        } catch { if !stopped, !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func settingsChanged() {
        guard !applying, !stopped, loaded else { return }
        for key in Self.keys {
            let value = Self.text(key)
            guard previous[key] != value else { continue }
            previous[key] = value
            send(
                "bifrost.ui.set",
                payload: try? JSONEncoder().encode(BifrostUIChange(key: key, value: value)))
        }
    }

    static func write<T>(_ key: String, value: T) {
        SharedDefaults.store.set(value, forKey: key)
        if let current {
            current.settingsChanged()
        } else {
            BifrostIPC.post(BifrostIPC.Name.settingsChanged)
        }
    }
    static func perform(_ action: String) {
        if let current {
            current.send("bifrost.ui." + action)
        } else {
            switch action {
            case "open": _ = BifrostOperationExecution.request(.open)
            case "reindex": _ = BifrostOperationExecution.request(.reindex)
            case "clear": _ = BifrostOperationExecution.clear()
            default: break
            }
        }
    }
    static func loadIndex() -> BifrostIndex? {
        if let current { return current.index }
        return BifrostIndexStore.shared.load()
    }
    private func send(_ operation: String, payload: Data? = Data("{}".utf8)) {
        guard !stopped, let payload else { return }
        let id = UUID()
        tasks[id] = Task { [weak self] in
            defer { self?.tasks[id] = nil }
            do {
                _ = try await invoke(operation, payload)
                await load()
            } catch { if !Task.isCancelled { self?.error = error.localizedDescription } }
        }
    }
    func shutdown() {
        stopped = true
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil; index = nil; loaded = false
    }
    private static func text(_ key: String) -> String {
        if boolKeys.contains(key) {
            let fallback =
                key == AppStorageKeys.Bifrost.enabled
                || BifrostSource.allCases.first(where: { $0.defaultsKey == key })?.isEnabled()
                    == true
            return (SharedDefaults.store.object(forKey: key) as? Bool ?? fallback)
                ? "true" : "false"
        }
        if intKeys.contains(key) {
            let fallback =
                key == AppStorageKeys.Bifrost.resultLimit
                ? BifrostQuery.defaultLimit : key == "bifrostHotKeyCode" ? 49 : 2048
            return String(SharedDefaults.store.object(forKey: key) as? Int ?? fallback)
        }
        return SharedDefaults.store.string(forKey: key)
            ?? (key == AppStorageKeys.Bifrost.popupAt ? PopupPosition.center.rawValue : "")
    }
    static func set(_ key: String, value: String) throws {
        guard keys.contains(key), value.utf8.count <= 131_072 else {
            throw ExtensionPeerError.invalidRequest
        }
        if boolKeys.contains(key) {
            guard ["true", "false"].contains(value) else { throw ExtensionPeerError.invalidRequest }
            SharedDefaults.store.set(value == "true", forKey: key)
        } else if intKeys.contains(key) {
            guard let number = Int(value), (0...65535).contains(number),
                key != AppStorageKeys.Bifrost.resultLimit
                    || (BifrostQuery.minimumResultLimit...BifrostQuery.maximumResultLimit).contains(
                        number)
            else { throw ExtensionPeerError.invalidRequest }
            SharedDefaults.store.set(number, forKey: key)
        } else {
            if key == AppStorageKeys.Bifrost.popupAt {
                guard PopupPosition.allCases.contains(where: { $0.rawValue == value }) else {
                    throw ExtensionPeerError.invalidRequest
                }
            } else if !value.isEmpty {
                guard let data = value.data(using: .utf8),
                    (try? JSONSerialization.jsonObject(with: data)) is [Any]
                else { throw ExtensionPeerError.invalidRequest }
            }
            SharedDefaults.store.set(value, forKey: key)
        }
    }
    static func execute(_ command: String, payload: Data, worker: BifrostWorker) throws -> Data {
        switch command {
        case "bifrost.ui.settings":
            guard payload == Data("{}".utf8) else { throw ExtensionPeerError.invalidRequest }
            return try JSONEncoder().encode(
                BifrostUISettings(
                    values: Dictionary(uniqueKeysWithValues: keys.map { ($0, text($0)) }),
                    index: BifrostIndexStore.shared.load()))
        case "bifrost.ui.set":
            let change = try JSONDecoder().decode(BifrostUIChange.self, from: payload)
            try set(change.key, value: change.value)
            BifrostIPC.post(BifrostIPC.Name.settingsChanged)
            worker.configureHotKey()
        case "bifrost.ui.open":
            guard payload == Data("{}".utf8) else { throw ExtensionPeerError.invalidRequest }
            BifrostPanel.shared.show(query: "")
        case "bifrost.ui.reindex":
            guard payload == Data("{}".utf8) else { throw ExtensionPeerError.invalidRequest }
            worker.store.reindex()
        case "bifrost.ui.clear":
            guard payload == Data("{}".utf8) else { throw ExtensionPeerError.invalidRequest }
            _ = BifrostOperationExecution.clear()
        default: throw ExtensionPeerError.invalidRequest
        }
        return Data("{}".utf8)
    }
}
