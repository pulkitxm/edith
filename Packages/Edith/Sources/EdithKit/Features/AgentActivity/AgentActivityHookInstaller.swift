import CoreFoundation
import Foundation

public enum AgentActivityHookScope: Equatable, Sendable {
    case global
    case project(URL)
}

public struct AgentActivityHookPlan: Equatable, Sendable {
    public let provider: AgentActivityProvider
    public let url: URL
    public let original: Data?
    public let replacement: Data?
    public var changed: Bool { original != replacement }
}

public struct AgentActivityHookInstallation: Equatable, Sendable {
    public let url: URL
    public let backupURL: URL?
    public let changed: Bool
}

public enum AgentActivityHookInstallerError: LocalizedError {
    case invalidConfiguration, configurationChanged, unrelatedPlugin, inputTooLarge
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The existing hook configuration is invalid. It was left unchanged."
        case .configurationChanged:
            "The hook configuration changed after preview. Preview it again."
        case .unrelatedPlugin:
            "A different plugin already uses this filename. It was left unchanged."
        case .inputTooLarge:
            "The hook configuration exceeds the supported size. It was left unchanged."
        }
    }
}

public struct AgentActivityHookInstaller: Sendable {
    public static let integrationID = "edith-surfaces"
    private let home: URL
    private let executable: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, executable: URL) {
        self.home = home
        self.executable = executable
    }

    public func configurationURL(
        provider: AgentActivityProvider, scope: AgentActivityHookScope
    ) -> URL {
        let root: URL
        if case .project(let project) = scope { root = project } else { root = home }
        let path: String
        switch provider {
        case .claude: path = ".claude/settings.json"
        case .codex: path = ".codex/hooks.json"
        case .gemini: path = ".gemini/settings.json"
        case .cursor: path = ".cursor/hooks.json"
        case .opencode:
            path =
                scope == .global
                ? ".config/opencode/plugins/edith-surfaces.ts"
                : ".opencode/plugins/edith-surfaces.ts"
        }
        return root.appendingPathComponent(path).resolvingSymlinksInPath()
    }

    public func plan(
        provider: AgentActivityProvider, scope: AgentActivityHookScope = .global, enabled: Bool
    ) throws -> AgentActivityHookPlan {
        let url = configurationURL(provider: provider, scope: scope)
        let original = try read(url)
        let replacement: Data?
        if provider == .opencode {
            if let original, !String(decoding: original, as: UTF8.self).contains(Self.pluginMarker)
            {
                throw AgentActivityHookInstallerError.unrelatedPlugin
            }
            replacement = enabled ? Data(openCodePlugin.utf8) : nil
        } else if provider == .cursor {
            replacement = try cursorConfiguration(original, enabled: enabled)
        } else {
            var root: [String: Any] = [:]
            if let original {
                guard
                    let object = try JSONSerialization.jsonObject(with: original) as? [String: Any]
                else {
                    throw AgentActivityHookInstallerError.invalidConfiguration
                }
                root = object
            }
            if let existing = root["hooks"], !(existing is [String: Any]) {
                throw AgentActivityHookInstallerError.invalidConfiguration
            }
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            var removedOwned = false
            for (event, value) in hooks {
                guard let groups = value as? [[String: Any]] else {
                    throw AgentActivityHookInstallerError.invalidConfiguration
                }
                var retained: [[String: Any]] = []
                for var group in groups {
                    guard let handlers = group["hooks"] as? [[String: Any]] else {
                        throw AgentActivityHookInstallerError.invalidConfiguration
                    }
                    let filtered = handlers.filter { !Self.owns($0) }
                    removedOwned = removedOwned || filtered.count != handlers.count
                    if filtered.count == handlers.count {
                        retained.append(group)
                    } else if !filtered.isEmpty {
                        group["hooks"] = filtered; retained.append(group)
                    }
                }
                hooks[event] = retained.isEmpty ? nil : retained
            }
            if enabled {
                for event in events(provider) {
                    var groups = hooks[event] as? [[String: Any]] ?? []
                    let permission = event == "PermissionRequest"
                    let terminal = event == "SessionEnd" || event == "Interrupt"
                    var handler: [String: Any] = [
                        "type": "command", "command": command(provider),
                        "timeout": (permission ? 120 : (terminal ? 3 : 5))
                            * (provider == .gemini ? 1000 : 1),
                    ]
                    if provider != .gemini && !permission && !terminal { handler["async"] = true }
                    groups.append(["hooks": [handler]])
                    hooks[event] = groups
                }
            }
            if !enabled && !removedOwned {
                return AgentActivityHookPlan(
                    provider: provider, url: url, original: original, replacement: original)
            }
            root["hooks"] = hooks.isEmpty ? nil : hooks
            replacement =
                try JSONSerialization.data(
                    withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
                + Data("\n".utf8)
        }
        return AgentActivityHookPlan(
            provider: provider, url: url, original: original, replacement: replacement)
    }

    private func cursorConfiguration(_ original: Data?, enabled: Bool) throws -> Data? {
        var root: [String: Any] = [:]
        if let original {
            guard let object = try JSONSerialization.jsonObject(with: original) as? [String: Any]
            else { throw AgentActivityHookInstallerError.invalidConfiguration }
            root = object
        }
        if let value = root["version"] {
            guard let version = value as? NSNumber,
                CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1
            else { throw AgentActivityHookInstallerError.invalidConfiguration }
        }
        if let existing = root["hooks"], !(existing is [String: Any]) {
            throw AgentActivityHookInstallerError.invalidConfiguration
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var removedOwned = false
        for (event, value) in hooks {
            guard let handlers = value as? [[String: Any]]
            else { throw AgentActivityHookInstallerError.invalidConfiguration }
            let retained = handlers.filter { !Self.owns($0) }
            removedOwned = removedOwned || retained.count != handlers.count
            hooks[event] = retained.isEmpty ? nil : retained
        }
        if enabled {
            root["version"] = 1
            for event in events(.cursor) {
                var handlers = hooks[event] as? [[String: Any]] ?? []
                handlers.append([
                    "type": "command", "command": command(.cursor), "timeout": 5,
                    "failClosed": false,
                ])
                hooks[event] = handlers
            }
        } else if !removedOwned {
            return original
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        return try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            + Data("\n".utf8)
    }

    public func apply(_ plan: AgentActivityHookPlan) throws -> AgentActivityHookInstallation {
        guard try read(plan.url) == plan.original else {
            throw AgentActivityHookInstallerError.configurationChanged
        }
        guard plan.changed else {
            return AgentActivityHookInstallation(url: plan.url, backupURL: nil, changed: false)
        }
        let files = FileManager.default
        let directory = plan.url.deletingLastPathComponent()
        try files.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let permissions =
            (try? files.attributesOfItem(atPath: plan.url.path)[.posixPermissions]) ?? 0o600
        var backup: URL?
        if let original = plan.original {
            let destination = directory.appendingPathComponent(
                plan.url.lastPathComponent + ".edith-backup-" + UUID().uuidString)
            guard
                files.createFile(
                    atPath: destination.path, contents: original,
                    attributes: [.posixPermissions: 0o600])
            else {
                throw CocoaError(.fileWriteUnknown)
            }
            backup = destination
        }
        if let replacement = plan.replacement {
            try replacement.write(to: plan.url, options: .atomic)
            try files.setAttributes([.posixPermissions: permissions], ofItemAtPath: plan.url.path)
        } else if plan.original != nil {
            try files.removeItem(at: plan.url)
        }
        return AgentActivityHookInstallation(url: plan.url, backupURL: backup, changed: true)
    }

    private func read(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 2_097_152 else { throw AgentActivityHookInstallerError.inputTooLarge }
        return try Data(contentsOf: url)
    }

    private static func owns(_ handler: [String: Any]) -> Bool {
        handler["type"] as? String == "command"
            && (handler["command"] as? String)?.contains("--integration-id " + integrationID)
                == true
    }

    private func command(_ provider: AgentActivityProvider) -> String {
        ShellQuote.command([
            executable.path, "agent", "activity", "hook", "--provider", provider.rawValue,
            "--integration-id", Self.integrationID,
        ])
    }

    private func events(_ provider: AgentActivityProvider) -> [String] {
        if provider == .gemini {
            return [
                "SessionStart", "SessionEnd", "BeforeAgent", "AfterAgent", "BeforeTool",
                "AfterTool",
                "Notification",
            ]
        }
        if provider == .cursor {
            return [
                "sessionStart", "sessionEnd", "postToolUse", "postToolUseFailure",
                "afterAgentThought",
                "afterAgentResponse", "stop",
            ]
        }
        let shared = [
            "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
            "SubagentStart", "SubagentStop", "Stop", "PermissionRequest",
        ]
        return shared
            + (provider == .claude
                ? [
                    "Notification", "StopFailure", "PostToolUseFailure", "PermissionDenied",
                    "Elicitation", "ElicitationResult",
                ]
                : ["Interrupt"])
    }

    private static let pluginMarker = "const integrationID = \"edith-surfaces\""

    public var openCodePlugin: String {
        let encodedPath = String(
            decoding: try! JSONEncoder().encode(executable.path), as: UTF8.self)
        return """
            import type { Plugin } from "@opencode-ai/plugin"

            const integrationID = "edith-surfaces"
            const executable = \(encodedPath)

            export const EdithSurfaces: Plugin = async ({ client, directory }) => {
              const active = new Map<string, ReturnType<typeof Bun.spawn>>()
              const events = new Set(["session.created", "session.status", "session.idle", "session.error", "session.deleted", "permission.asked", "permission.replied"])

              const forward = async (event: any) => {
                const process = Bun.spawn([executable, "agent", "activity", "hook", "--provider", "opencode", "--integration-id", integrationID], {
                  stdin: new Blob([JSON.stringify({ ...event, directory })]), stdout: "pipe", stderr: "ignore"
                })
                const requestID = event.type === "permission.asked" ? event.properties.id : undefined
                if (requestID) active.set(requestID, process)
                const timer = setTimeout(() => process.kill(), requestID ? 120000 : 5000)
                try {
                  const output = await new Response(process.stdout).text()
                  const code = await process.exited
                  if (code !== 0 || !requestID || active.get(requestID) !== process) return
                  const result = JSON.parse(output)
                  if (result.choice !== "allowOnce" && result.choice !== "deny") return
                  await client.postSessionIdPermissionsPermissionId({
                    path: { id: event.properties.sessionID, permissionID: requestID },
                    body: { response: result.choice === "allowOnce" ? "once" : "reject" },
                    query: { directory }
                  })
                } catch {} finally {
                  clearTimeout(timer)
                  if (requestID && active.get(requestID) === process) active.delete(requestID)
                }
              }

              return {
                event: async ({ event }) => {
                  const type: string = event.type
                  if (!events.has(type)) return
                  const properties = event.properties as any
                  if (type === "permission.replied") {
                    active.get(properties.requestID)?.kill()
                    active.delete(properties.requestID)
                  }
                  if (type === "permission.asked" && active.has(properties.id)) return
                  void forward(event).catch(() => {})
                },
                "tool.execute.before": async (input, output) => {
                  void forward({ type: "tool.execute.before", properties: { sessionID: input.sessionID, tool: input.tool, metadata: output.args } }).catch(() => {})
                },
                "tool.execute.after": async (input) => {
                  void forward({ type: "tool.execute.after", properties: { sessionID: input.sessionID, tool: input.tool } }).catch(() => {})
                }
              }
            }

            """
    }
}
