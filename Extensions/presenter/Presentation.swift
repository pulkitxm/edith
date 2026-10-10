import CoreFoundation
import EdithExtensionSupport
import Foundation
import Observation

struct ControlPresentationPacket: Codable {
    let preferences: Data
    let state: ControlPresentationState
}

struct ControlPreferenceUpdate: Codable {
    let values: Data
    let removed: [String]
}

struct ControlPresentationAction: Codable {
    let action: String
    var value: String = ""
}

struct ControlPresentationState: Codable {
    var muted = false
    var error: String?
    var cpu = 0.0
    var memory = 0.0
    var jevConfigured = false
}

enum ControlPresentationContract {
    static let writable: Set<String> = [
        "presenterAskJev", "presenterAutoEnabled", "presenterBlurAgents", "presenterBlurAttention",
        "presenterBlurBrowser", "presenterBlurCalendar", "presenterBlurCamera",
        "presenterBlurDatabase", "presenterBlurFleet", "presenterBlurMemory", "presenterBlurMoney",
        "presenterBlurMusic", "presenterBlurReview", "presenterBlurRunningApps",
        "presenterBlurShelf", "presenterBlurSiteAudit", "presenterBlurStudio", "presenterBlurUsage",
        "presenterDetectMirroring", "presenterDetectRecording", "presenterDetectScreenSharing",
        "presenterHideMenuBarNumbers", "presenterHotKeyCode", "presenterHotKeyLabel",
        "presenterHotKeyMods", "presenterMode",
    ]
    static let readable: Set<String> = writable.union([
        "presenterAutoActive", "presenterAutoPaused", "presenterAutoReason", "presenterEnabled",
    ])

    static func values(from defaults: UserDefaults, keys: Set<String>) -> [String: Any] {
        Dictionary(
            uniqueKeysWithValues: keys.compactMap { key in
                defaults.object(forKey: key).map { (key, $0) }
            })
    }

    static func encode(_ values: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
    }

    static func decode(_ data: Data, keys: Set<String>) throws -> [String: Any] {
        guard data.count <= 262_144,
            let values = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil)
                as? [String: Any], Set(values.keys).isSubset(of: keys)
        else { throw ExtensionPeerError.invalidRequest }
        return values
    }

    @MainActor static func update(_ payload: Data, defaults: UserDefaults) throws {
        let update = try JSONDecoder().decode(ControlPreferenceUpdate.self, from: payload)
        let values = try decode(update.values, keys: writable)
        guard Set(update.removed).isSubset(of: writable),
            Set(update.removed).isDisjoint(with: values.keys)
        else { throw ExtensionPeerError.invalidRequest }
        for (key, value) in values {
            if let string = value as? String {
                guard string.utf8.count <= 4096 else { throw ExtensionPeerError.invalidRequest }
            } else if let number = value as? NSNumber {
                guard number.doubleValue.isFinite else { throw ExtensionPeerError.invalidRequest }
            } else {
                throw ExtensionPeerError.invalidRequest
            }
            guard valid(value, for: key) else { throw ExtensionPeerError.invalidRequest }
        }
        for key in update.removed { defaults.removeObject(forKey: key) }
        for (key, value) in values { defaults.set(value, forKey: key) }
    }

    static func valid(_ value: Any, for key: String) -> Bool {
        if stringKeys.contains(key) { return value is String }
        guard let number = value as? NSNumber else { return false }
        if boolKeys.contains(key) { return CFGetTypeID(number) == CFBooleanGetTypeID() }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        if let range = ranges[key] { return range.contains(number.doubleValue) }
        return number.doubleValue.rounded() == number.doubleValue && number.doubleValue >= 0
            && number.doubleValue <= Double(UInt32.max)
    }

    static let stringKeys: Set<String> = ["presenterHotKeyLabel"]
    static let boolKeys: Set<String> = [
        "presenterAskJev", "presenterAutoEnabled", "presenterBlurAgents", "presenterBlurAttention",
        "presenterBlurBrowser", "presenterBlurCalendar", "presenterBlurCamera",
        "presenterBlurDatabase", "presenterBlurFleet", "presenterBlurMemory", "presenterBlurMoney",
        "presenterBlurMusic", "presenterBlurReview", "presenterBlurRunningApps",
        "presenterBlurShelf", "presenterBlurSiteAudit", "presenterBlurStudio", "presenterBlurUsage",
        "presenterDetectMirroring", "presenterDetectRecording", "presenterDetectScreenSharing",
        "presenterHideMenuBarNumbers", "presenterMode",
    ]
    static let ranges: [String: ClosedRange<Double>] = [:]

    @MainActor static func snapshot(defaults: UserDefaults, state: ControlPresentationState) throws
        -> Data
    {
        try JSONEncoder().encode(
            ControlPresentationPacket(
                preferences: encode(values(from: defaults, keys: readable)), state: state))
    }
}

@MainActor
@Observable
final class ControlPresentation {
    private(set) var state = ControlPresentationState()
    private(set) var error: String?
    private(set) var ready: Bool
    let active: Bool
    private let defaults: UserDefaults
    private let client: ExtensionEngineClient?
    private let invoke: (String, Data) async throws -> Data
    private var polling: Task<Void, Never>?
    private var writing: Task<Void, Never>?
    private var actions: [UUID: Task<Void, Never>] = [:]
    private var observer: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var baseline: [String: Any] = [:]
    private var applying = false
    private var stopped = false
    private var revision = 0

    init(
        client: ExtensionEngineClient?, defaults: UserDefaults = SharedDefaults.store,
        invoke: ((String, Data) async throws -> Data)? = nil
    ) {
        self.client = client
        self.defaults = defaults
        active = client != nil || invoke != nil
        ready = !active
        self.invoke =
            invoke ?? { operation, payload in
                guard let client else { throw ExtensionPeerError.unavailable }
                return try await client.invoke(operation, payload: payload)
            }
        baseline = ControlPresentationContract.values(
            from: defaults, keys: ControlPresentationContract.writable)
    }

    func start() {
        guard !stopped, active, polling == nil else { return }
        observer = IPC.observe(IPC.Name.settingsChanged) { [weak self] in
            MainActor.assumeIsolated { self?.changed() }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.changed() } }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.stopped else { return }
                await self.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    func changed() {
        guard !applying, !stopped, active, ready else { return }
        let values = ControlPresentationContract.values(
            from: defaults, keys: ControlPresentationContract.writable)
        guard !(values as NSDictionary).isEqual(to: baseline) else { return }
        revision += 1
        guard writing == nil else { return }
        writing = Task { [weak self] in
            guard let self else { return }
            defer { self.writing = nil }
            while !self.stopped && !Task.isCancelled {
                let revision = self.revision
                let values = ControlPresentationContract.values(
                    from: self.defaults, keys: ControlPresentationContract.writable)
                let changed = values.filter { key, value in
                    guard let old = self.baseline[key] else { return true }
                    return !(NSDictionary(dictionary: [key: value])).isEqual(to: [key: old])
                }
                let removed = Array(Set(self.baseline.keys).subtracting(values.keys))
                do {
                    let payload = try JSONEncoder().encode(
                        ControlPreferenceUpdate(
                            values: ControlPresentationContract.encode(changed), removed: removed))
                    _ = try await self.invoke("presenter.ui.update", payload)
                    guard !self.stopped else { return }
                    self.baseline = values
                    self.error = nil
                } catch {
                    if !self.stopped { self.error = error.localizedDescription }
                    return
                }
                if revision == self.revision { break }
            }
        }
    }

    func refresh() async {
        guard active, !stopped, writing == nil, actions.isEmpty else { return }
        let revision = revision
        do {
            let data = try await invoke("presenter.ui.read", Data("{}".utf8))
            let packet = try JSONDecoder().decode(ControlPresentationPacket.self, from: data)
            let values = try ControlPresentationContract.decode(
                packet.preferences, keys: ControlPresentationContract.readable)
            guard !stopped, revision == self.revision, writing == nil, actions.isEmpty else {
                return
            }
            applying = true
            for key in ControlPresentationContract.readable {
                if let value = values[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            baseline = ControlPresentationContract.values(
                from: defaults, keys: ControlPresentationContract.writable)
            state = packet.state
            error = nil
            ready = true
            applying = false
            IPC.post(IPC.Name.settingsChanged)
        } catch {
            if !stopped { self.error = error.localizedDescription }
        }
    }

    func perform(_ action: String, value: String = "") {
        guard active, ready, !stopped, actions.count < 8 else { return }
        revision += 1
        let token = UUID()
        actions[token] = Task { [weak self] in
            guard let self else { return }
            defer { self.actions[token] = nil }
            do {
                let payload = try JSONEncoder().encode(
                    ControlPresentationAction(action: action, value: value))
                _ = try await self.invoke("presenter.ui.action", payload)
                guard !self.stopped else { return }
                self.error = nil
            } catch { if !self.stopped { self.error = error.localizedDescription } }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        revision += 1
        polling?.cancel(); polling = nil
        writing?.cancel(); writing = nil
        actions.values.forEach { $0.cancel() }; actions.removeAll()
        IPC.stopObserving(observer); observer = nil
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        client?.invalidate()
    }
}

import EdithExtensionUI
import SwiftUI

struct ControlSettingsHost<Content: View>: View {
    let presentation: ControlPresentation
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            if let error = presentation.error {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle")
                    Button("Retry") {
                        presentation.changed(); Task { await presentation.refresh() }
                    }
                }.padding()
            }
            content().disabled(presentation.active && !presentation.ready)
        }.task { presentation.start() }
    }
}
