import EdithExtensionSupport
import Foundation

struct HerdrUIHookPreview: Codable {
    let id: UUID
    let provider: AgentActivityProvider
    let url: URL
    let replacementBytes: Int?
}

struct HerdrUIHookBytes: Codable {
    let bytes: Data
    let nextOffset: Int
}

@MainActor final class HerdrUIHookPlans {
    private struct Prepared {
        let plan: AgentActivityHookPlan
        let scope: AgentActivityHookScope
        let enabled: Bool
        let deadline: Date
    }
    private var stopped = false
    private var prepared: [UUID: Prepared] = [:]
    private let files: AgentActivityHookFiles
    private let installer: AgentActivityHookInstaller

    init(files: AgentActivityHookFiles, installer: AgentActivityHookInstaller) {
        self.files = files
        self.installer = installer
    }

    func execute(_ operation: String, payload: Data) async throws -> Data {
        guard !stopped, payload.count <= 4096,
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { throw ExtensionPeerError.invalidRequest }
        prepared = prepared.filter { $0.value.deadline > Date() }
        switch operation {
        case "herdr.ui.hook.plan":
            guard Set(object.keys).isSubset(of: ["provider", "enabled", "project"]),
                let raw = object["provider"] as? String,
                let provider = AgentActivityProvider(rawValue: raw),
                let enabled = object["enabled"] as? NSNumber,
                CFGetTypeID(enabled) == CFBooleanGetTypeID(),
                prepared.count < 8
            else { throw ExtensionPeerError.invalidRequest }
            let scope: AgentActivityHookScope
            if let input = object["project"] {
                guard let path = input as? String, path.hasPrefix("/"), path.utf8.count <= 4096,
                    !path.utf8.contains(0)
                else { throw ExtensionPeerError.invalidRequest }
                scope = .project(URL(fileURLWithPath: path))
            } else {
                scope = .global
            }
            let plan = try await files.plan(
                installer, provider: provider, scope: scope, enabled: enabled.boolValue)
            try Task.checkCancellation()
            guard !stopped else { throw ExtensionPeerError.unavailable }
            guard (plan.replacement?.count ?? 0) <= 2_097_152 else {
                throw ExtensionPeerError.invalidRequest
            }
            let id = UUID()
            prepared[id] = Prepared(
                plan: plan, scope: scope, enabled: enabled.boolValue,
                deadline: Date().addingTimeInterval(120))
            return try JSONEncoder().encode(
                HerdrUIHookPreview(
                    id: id, provider: provider, url: plan.url,
                    replacementBytes: plan.replacement?.count))
        case "herdr.ui.hook.read", "herdr.ui.hook.apply":
            guard Set(object.keys) == (operation.hasSuffix("read") ? ["id", "offset"] : ["id"]),
                let raw = object["id"] as? String, let id = UUID(uuidString: raw),
                let value = prepared[id]
            else { throw ExtensionPeerError.invalidRequest }
            if operation.hasSuffix("apply") {
                prepared[id] = nil
                let result = try await files.apply(
                    installer, plan: value.plan, scope: value.scope, enabled: value.enabled)
                try Task.checkCancellation()
                return try JSONEncoder().encode(result)
            }
            guard let number = object["offset"] as? NSNumber,
                CFGetTypeID(number) != CFBooleanGetTypeID(),
                number.doubleValue == Double(number.intValue), let bytes = value.plan.replacement,
                (0...bytes.count).contains(number.intValue)
            else { throw ExtensionPeerError.invalidRequest }
            let chunk = Data(bytes.dropFirst(number.intValue).prefix(32768))
            return try JSONEncoder().encode(
                HerdrUIHookBytes(bytes: chunk, nextOffset: number.intValue + chunk.count))
        default: throw ExtensionPeerError.invalidRequest
        }
    }

    func shutdown() { stopped = true; prepared.removeAll() }
}

@MainActor extension AgentActivityMonitor {
    func prepareHook(
        _ installer: AgentActivityHookInstaller, provider: AgentActivityProvider,
        scope: AgentActivityHookScope, enabled: Bool
    ) async throws -> (AgentActivityHookPlan, UUID?) {
        guard let uiClient else {
            return (
                try await hookFiles.plan(
                    installer, provider: provider, scope: scope, enabled: enabled), nil
            )
        }
        var object: [String: Any] = ["provider": provider.rawValue, "enabled": enabled]
        if case .project(let url) = scope { object["project"] = url.path }
        let metadata = try JSONDecoder().decode(
            HerdrUIHookPreview.self,
            from: await uiClient.perform("herdr.ui.hook.plan", object: object))
        guard metadata.provider == provider, metadata.url.isFileURL,
            metadata.url.path.hasPrefix("/"), metadata.url.path.utf8.count <= 4096,
            metadata.replacementBytes.map({ (0...2_097_152).contains($0) }) ?? true
        else { throw ExtensionPeerError.invalidRequest }
        var bytes: Data?
        if let count = metadata.replacementBytes {
            bytes = Data()
            while bytes!.count < count {
                let offset = bytes!.count
                let chunk = try JSONDecoder().decode(
                    HerdrUIHookBytes.self,
                    from: await uiClient.perform(
                        "herdr.ui.hook.read",
                        object: ["id": metadata.id.uuidString, "offset": offset]))
                guard !chunk.bytes.isEmpty, chunk.bytes.count <= 32768,
                    chunk.nextOffset == offset + chunk.bytes.count, chunk.nextOffset <= count
                else { throw ExtensionPeerError.invalidRequest }
                bytes!.append(chunk.bytes)
            }
        }
        return (
            .init(
                provider: metadata.provider, url: metadata.url, original: nil, replacement: bytes),
            metadata.id
        )
    }

    func applyHook(
        _ installer: AgentActivityHookInstaller, plan: AgentActivityHookPlan,
        scope: AgentActivityHookScope, enabled: Bool, token: UUID?
    ) async throws -> AgentActivityHookInstallation {
        guard let uiClient else {
            return try await hookFiles.apply(installer, plan: plan, scope: scope, enabled: enabled)
        }
        guard let token else { throw ExtensionPeerError.invalidRequest }
        return try JSONDecoder().decode(
            AgentActivityHookInstallation.self,
            from: await uiClient.perform("herdr.ui.hook.apply", object: ["id": token.uuidString]))
    }
}
