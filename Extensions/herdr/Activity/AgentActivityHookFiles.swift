import EdithExtensionSupport
import Foundation

actor AgentActivityHookFiles {
    private struct Record: Codable {
        var provider: AgentActivityProvider
        var project: String?
        var original: Data?
        var replacement: Data?
        var consent: Bool
        var active: Bool
        var scope: AgentActivityHookScope {
            project.map { .project(URL(fileURLWithPath: $0)) } ?? .global
        }
    }
    private let journal: URL
    init(root: URL = ExtensionData.root) {
        journal = root.appendingPathComponent("provider-hook-ownership.json")
    }
    func plan(
        _ installer: AgentActivityHookInstaller, provider: AgentActivityProvider,
        scope: AgentActivityHookScope, enabled: Bool
    ) throws -> AgentActivityHookPlan {
        try Task.checkCancellation()
        let result = try installer.plan(provider: provider, scope: scope, enabled: enabled)
        try Task.checkCancellation()
        return result
    }
    func apply(
        _ installer: AgentActivityHookInstaller, plan: AgentActivityHookPlan,
        scope: AgentActivityHookScope, enabled: Bool
    ) throws -> AgentActivityHookInstallation {
        try Task.checkCancellation()
        guard installer.configurationURL(provider: plan.provider, scope: scope) == plan.url else {
            throw AgentActivityHookInstallerError.invalidConfiguration
        }
        var records = try load()
        let project: String?
        if case .project(let root) = scope {
            project = root.standardizedFileURL.path
        } else {
            project = nil
        }
        let index = records.firstIndex { $0.provider == plan.provider && $0.project == project }
        let prior = index.map { records[$0] }
        let record = Record(
            provider: plan.provider, project: project,
            original: enabled && prior?.active == true ? prior?.original : plan.original,
            replacement: plan.replacement, consent: enabled, active: true)
        if let index {
            records[index] = record
        } else {
            guard records.count < 32 else { throw AgentActivityHookInstallerError.inputTooLarge };
            records.append(record)
        }
        try save(records)
        let result = try installer.apply(plan)
        if !enabled {
            let i = index ?? records.count - 1
            records[i].active = false
            records[i].original = plan.replacement
            records[i].replacement = nil
            try save(records)
        }
        return result
    }
    func suspend(_ installer: AgentActivityHookInstaller) throws {
        var records = try load()
        for i in records.indices where records[i].active {
            let record = records[i]
            let removal = try installer.plan(
                provider: record.provider, scope: record.scope, enabled: false)
            if removal.original == record.replacement {
                _ = try installer.apply(
                    AgentActivityHookPlan(
                        provider: record.provider, url: removal.url, original: removal.original,
                        replacement: record.original))
            } else if removal.original != record.original {
                _ = try installer.apply(removal)
                records[i].original = removal.replacement
            }
            records[i].active = false
            records[i].replacement = nil
            try save(records)
        }
    }
    func resume(_ installer: AgentActivityHookInstaller) throws {
        try suspend(installer)
        let records = try load()
        for record in records where record.consent {
            try Task.checkCancellation()
            let plan = try installer.plan(
                provider: record.provider, scope: record.scope, enabled: true)
            guard plan.original == record.original else { continue }
            _ = try apply(installer, plan: plan, scope: record.scope, enabled: true)
        }
    }
    private func load() throws -> [Record] {
        guard FileManager.default.fileExists(atPath: journal.path) else { return [] }
        let size = try journal.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 33_554_432 else { throw AgentActivityHookInstallerError.inputTooLarge }
        let result = try JSONDecoder().decode([Record].self, from: Data(contentsOf: journal))
        guard result.count <= 32,
            result.allSatisfy({ record in
                (record.original?.count ?? 0) <= 2_097_152
                    && (record.replacement?.count ?? 0) <= 2_097_152
                    && (record.project.map {
                        $0.hasPrefix("/") && $0.utf8.count <= 4096 && !$0.utf8.contains(0)
                    } ?? true)
            })
        else { throw AgentActivityHookInstallerError.invalidConfiguration }
        return result
    }
    private func save(_ records: [Record]) throws {
        let data = try JSONEncoder().encode(records)
        guard data.count <= 33_554_432 else { throw AgentActivityHookInstallerError.inputTooLarge }
        try FileManager.default.createDirectory(
            at: journal.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: journal, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: journal.path)
    }
}
