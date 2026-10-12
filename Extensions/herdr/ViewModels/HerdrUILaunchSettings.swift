import EdithExtensionSupport
import Foundation
import Observation

struct HerdrUILaunchSettingsState: Codable {
    let kind: String
    let command: String
    let options: AgentLaunchOptions
    let catalog: AgentLaunchCatalog?
}

@MainActor enum HerdrUILaunchSettingsEngine {
    static func execute(_ operation: String, payload: Data, worker: HerdrWorker) async throws
        -> Data
    {
        guard payload.count <= 16384,
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let kind = object["kind"] as? String, HerdrLaunchSettings.kinds.contains(kind)
        else { throw ExtensionPeerError.invalidRequest }
        let defaults = worker.store.uiDefaults
        if operation == "herdr.ui.launchSettings.save" {
            guard
                Set(object.keys) == [
                    "kind", "baselineCommand", "baselineOptions", "command", "options",
                ],
                let command = object["command"] as? String, command.utf8.count <= 4096,
                !command.utf8.contains(0),
                let baseline = object["baselineCommand"] as? String
            else { throw ExtensionPeerError.invalidRequest }
            func options(_ key: String) throws -> AgentLaunchOptions {
                guard let value = object[key] as? [String: Any],
                    Set(value.keys).isSubset(of: ["model", "effort", "fast"])
                else { throw ExtensionPeerError.invalidRequest }
                let options = try JSONDecoder().decode(
                    AgentLaunchOptions.self, from: JSONSerialization.data(withJSONObject: value))
                guard
                    [options.model, options.effort].compactMap({ $0 }).allSatisfy({
                        $0.utf8.count <= 256 && !$0.utf8.contains(0)
                    })
                else { throw ExtensionPeerError.invalidRequest }
                return options
            }
            guard baseline == HerdrLaunchSettings.command(for: kind, in: defaults),
                try options("baselineOptions")
                    == HerdrLaunchSettings.options(for: kind, in: defaults)
            else {
                throw ExtensionPeerError.rejected(
                    "The launch settings changed in another view. Refresh and try again.")
            }
            HerdrLaunchSettings.setCommand(command, for: kind, in: defaults)
            HerdrLaunchSettings.setOptions(try options("options"), for: kind, in: defaults)
        } else {
            guard operation == "herdr.ui.launchSettings.read",
                Set(object.keys) == ["kind", "refresh"],
                let refresh = object["refresh"] as? NSNumber,
                CFGetTypeID(refresh) == CFBooleanGetTypeID()
            else { throw ExtensionPeerError.invalidRequest }
            if let launchKind = AgentLaunchKind(kind: kind) {
                _ = await worker.catalogs.catalog(for: launchKind, refresh: refresh.boolValue)
            }
        }
        try Task.checkCancellation()
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        let catalog: AgentLaunchCatalog?
        if let launchKind = AgentLaunchKind(kind: kind) {
            catalog = await worker.catalogs.cached(for: launchKind)
        } else {
            catalog = nil
        }
        return try JSONEncoder().encode(
            HerdrUILaunchSettingsState(
                kind: kind,
                command: HerdrLaunchSettings.command(for: kind, in: defaults),
                options: HerdrLaunchSettings.options(for: kind, in: defaults), catalog: catalog))
    }
}

@MainActor @Observable final class HerdrUILaunchSettingsModel {
    let kind: String
    var command = ""
    var options = AgentLaunchOptions.none
    private(set) var catalog: AgentLaunchCatalog?
    private(set) var error: String?
    private(set) var loading = false
    var ready: Bool { baseline != nil && !stopped }
    private let client: HerdrUIClient
    private var baseline: HerdrUILaunchSettingsState?
    private var write: Task<Void, Never>?
    private var dirty = false
    private var stopped = false

    init(kind: String, client: HerdrUIClient) { self.kind = kind; self.client = client }

    func read(refresh: Bool = false) async {
        guard !stopped else { return }
        loading = true
        defer { loading = false }
        do {
            let data = try await client.perform(
                "herdr.ui.launchSettings.read", object: ["kind": kind, "refresh": refresh])
            let value = try decode(data)
            guard !stopped, !dirty, write == nil else { return }
            adopt(value)
        } catch { if !stopped { self.error = error.localizedDescription } }
    }

    func update(command: String? = nil, options: AgentLaunchOptions? = nil) {
        guard !stopped, baseline != nil else { return }
        if let command { self.command = command }
        if let options { self.options = options }
        dirty = true
        guard write == nil else { return }
        write = Task { [weak self] in
            guard let self else { return }
            defer { self.write = nil }
            while self.dirty, !Task.isCancelled {
                self.dirty = false
                guard let baseline = self.baseline else { return }
                do {
                    func object(_ value: AgentLaunchOptions) throws -> Any {
                        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
                    }
                    let data = try await client.perform(
                        "herdr.ui.launchSettings.save",
                        object: [
                            "kind": kind, "baselineCommand": baseline.command,
                            "baselineOptions": try object(baseline.options),
                            "command": self.command, "options": try object(self.options),
                        ])
                    let value = try decode(data)
                    guard !stopped else { return }
                    self.baseline = value
                    if !self.dirty { adopt(value) }
                } catch { if !stopped { self.error = error.localizedDescription }; return }
            }
        }
    }

    func reset() { update(command: HerdrLaunchSettings.defaultHerdrSlug(for: kind) ?? "") }
    func shutdown() { stopped = true; write?.cancel() }

    private func decode(_ data: Data) throws -> HerdrUILaunchSettingsState {
        let value = try JSONDecoder().decode(HerdrUILaunchSettingsState.self, from: data)
        guard value.kind == kind, value.command.utf8.count <= 4096,
            value.catalog.map({ $0.kind.rawValue == kind && $0.models.count <= 4096 }) ?? true
        else { throw ExtensionPeerError.invalidRequest }
        return value
    }

    private func adopt(_ value: HerdrUILaunchSettingsState) {
        baseline = value
        command = value.command
        options = value.options
        catalog = value.catalog
        error = nil
    }
}
