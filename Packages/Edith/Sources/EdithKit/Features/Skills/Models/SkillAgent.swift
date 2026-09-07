import Foundation

public struct SkillAgent: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let directory: String
    public let detectionPaths: [String]

    public init(_ id: String, _ name: String, _ directory: String, _ detectionPaths: [String]) {
        self.id = id
        self.name = name
        self.directory = directory
        self.detectionPaths = detectionPaths
    }

    public func resolvedDirectory(home: URL, environment: [String: String]) -> URL {
        URL(fileURLWithPath: Self.resolve(directory, home: home, environment: environment))
    }

    public func isDetected(
        home: URL, environment: [String: String], exists: (String) -> Bool
    ) -> Bool {
        detectionPaths.contains { exists(Self.resolve($0, home: home, environment: environment)) }
    }

    private static func resolve(_ path: String, home: URL, environment: [String: String]) -> String
    {
        let roots = [
            "CODEX_HOME": ".codex", "CLAUDE_CONFIG_DIR": ".claude", "VIBE_HOME": ".vibe",
            "HERMES_HOME": ".hermes", "AUTOHAND_HOME": ".autohand", "GROK_HOME": ".grok",
        ]
        var result = path
        for (key, fallback) in roots {
            let override = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let root =
                override?.isEmpty == false ? override! : home.appendingPathComponent(fallback).path
            result = result.replacingOccurrences(of: "/ENV/" + key, with: root)
        }
        let config =
            environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? home.appendingPathComponent(".config").path
        return result.replacingOccurrences(of: "/CONFIG", with: config)
            .replacingOccurrences(of: "/HOME", with: home.path)
    }
}

public enum SkillAgentCatalog {
    public static let agents: [SkillAgent] = [
        SkillAgent("aider-desk", "AiderDesk", "/HOME/.aider-desk/skills", ["/HOME/.aider-desk"]),
        SkillAgent("amp", "Amp", "/CONFIG/agents/skills", ["/CONFIG/amp"]),
        SkillAgent(
            "antigravity", "Antigravity", "/HOME/.gemini/antigravity/skills",
            ["/HOME/.gemini/antigravity"]),
        SkillAgent(
            "antigravity-cli", "Antigravity CLI", "/HOME/.gemini/antigravity-cli/skills",
            ["/HOME/.gemini/antigravity-cli"]),
        SkillAgent("astrbot", "AstrBot", "/HOME/.astrbot/data/skills", ["/HOME/.astrbot"]),
        SkillAgent(
            "autohand-code", "Autohand Code CLI", "/ENV/AUTOHAND_HOME/skills",
            ["/ENV/AUTOHAND_HOME"]),
        SkillAgent("augment", "Augment", "/HOME/.augment/skills", ["/HOME/.augment"]),
        SkillAgent("bob", "IBM Bob", "/HOME/.bob/skills", ["/HOME/.bob"]),
        SkillAgent(
            "claude-code", "Claude Code", "/ENV/CLAUDE_CONFIG_DIR/skills",
            ["/ENV/CLAUDE_CONFIG_DIR"]),
        SkillAgent(
            "openclaw", "OpenClaw", "/HOME/.openclaw/skills",
            ["/HOME/.openclaw", "/HOME/.clawdbot", "/HOME/.moltbot"]),
        SkillAgent("cline", "Cline", "/HOME/.agents/skills", ["/HOME/.cline"]),
        SkillAgent(
            "codearts-agent", "CodeArts Agent", "/HOME/.codeartsdoer/skills",
            ["/HOME/.codeartsdoer"]),
        SkillAgent("codebuddy", "CodeBuddy", "/HOME/.codebuddy/skills", ["/HOME/.codebuddy"]),
        SkillAgent("codemaker", "Codemaker", "/HOME/.codemaker/skills", ["/HOME/.codemaker"]),
        SkillAgent("codestudio", "Code Studio", "/HOME/.codestudio/skills", ["/HOME/.codestudio"]),
        SkillAgent("codex", "Codex", "/ENV/CODEX_HOME/skills", ["/ENV/CODEX_HOME", "/etc/codex"]),
        SkillAgent(
            "command-code", "Command Code", "/HOME/.commandcode/skills", ["/HOME/.commandcode"]),
        SkillAgent("continue", "Continue", "/HOME/.continue/skills", ["/HOME/.continue"]),
        SkillAgent(
            "cortex", "Cortex Code", "/HOME/.snowflake/cortex/skills", ["/HOME/.snowflake/cortex"]),
        SkillAgent("crush", "Crush", "/HOME/.config/crush/skills", ["/HOME/.config/crush"]),
        SkillAgent("cursor", "Cursor", "/HOME/.cursor/skills", ["/HOME/.cursor"]),
        SkillAgent(
            "deepagents", "Deep Agents", "/HOME/.deepagents/agent/skills", ["/HOME/.deepagents"]),
        SkillAgent("devin", "Devin for Terminal", "/CONFIG/devin/skills", ["/CONFIG/devin"]),
        SkillAgent("dexto", "Dexto", "/HOME/.agents/skills", ["/HOME/.dexto"]),
        SkillAgent("droid", "Droid", "/HOME/.factory/skills", ["/HOME/.factory"]),
        SkillAgent("firebender", "Firebender", "/HOME/.firebender/skills", ["/HOME/.firebender"]),
        SkillAgent("forgecode", "ForgeCode", "/HOME/.forge/skills", ["/HOME/.forge"]),
        SkillAgent("gemini-cli", "Gemini CLI", "/HOME/.gemini/skills", ["/HOME/.gemini"]),
        SkillAgent("github-copilot", "GitHub Copilot", "/HOME/.copilot/skills", ["/HOME/.copilot"]),
        SkillAgent("goose", "Goose", "/CONFIG/goose/skills", ["/CONFIG/goose"]),
        SkillAgent("grok", "Grok Build", "/ENV/GROK_HOME/skills", ["/ENV/GROK_HOME"]),
        SkillAgent("hermes-agent", "Hermes Agent", "/ENV/HERMES_HOME/skills", ["/ENV/HERMES_HOME"]),
        SkillAgent(
            "inference-sh", "inference.sh", "/HOME/.inferencesh/skills", ["/HOME/.inferencesh"]),
        SkillAgent("jazz", "Jazz", "/HOME/.jazz/skills", ["/HOME/.jazz"]),
        SkillAgent("junie", "Junie", "/HOME/.junie/skills", ["/HOME/.junie"]),
        SkillAgent("iflow-cli", "iFlow CLI", "/HOME/.iflow/skills", ["/HOME/.iflow"]),
        SkillAgent("kilo", "Kilo Code", "/HOME/.kilocode/skills", ["/HOME/.kilocode"]),
        SkillAgent(
            "kimchi", "Kimchi", "/HOME/.config/kimchi/harness/skills", ["/HOME/.config/kimchi"]),
        SkillAgent(
            "kimi-code-cli", "Kimi Code CLI", "/HOME/.agents/skills",
            ["/HOME/.kimi-code", "/HOME/.kimi"]),
        SkillAgent("kiro-cli", "Kiro CLI", "/HOME/.kiro/skills", ["/HOME/.kiro"]),
        SkillAgent("kode", "Kode", "/HOME/.kode/skills", ["/HOME/.kode"]),
        SkillAgent("lingma", "Lingma", "/HOME/.lingma/skills", ["/HOME/.lingma"]),
        SkillAgent("loaf", "Loaf", "/HOME/.agents/skills", ["/HOME/.loaf"]),
        SkillAgent("mcpjam", "MCPJam", "/HOME/.mcpjam/skills", ["/HOME/.mcpjam"]),
        SkillAgent(
            "minimax-code", "MiniMax Code", "/HOME/.minimax/skills",
            ["/HOME/.minimax", "/Applications/MiniMax Code.app"]),
        SkillAgent("mistral-vibe", "Mistral Vibe", "/ENV/VIBE_HOME/skills", ["/ENV/VIBE_HOME"]),
        SkillAgent("moxby", "Moxby", "/HOME/.moxby/skills", ["/HOME/.moxby"]),
        SkillAgent("mux", "Mux", "/HOME/.mux/skills", ["/HOME/.mux"]),
        SkillAgent("opencode", "OpenCode", "/CONFIG/opencode/skills", ["/CONFIG/opencode"]),
        SkillAgent("openhands", "OpenHands", "/HOME/.openhands/skills", ["/HOME/.openhands"]),
        SkillAgent("ona", "Ona", "/HOME/.ona/skills", ["/HOME/.ona"]),
        SkillAgent("pi", "Pi", "/HOME/.pi/agent/skills", ["/HOME/.pi/agent"]),
        SkillAgent(
            "posit-assistant", "Posit Assistant", "/HOME/.posit/assistant/skills",
            ["/HOME/.posit/assistant", "/HOME/.positai"]),
        SkillAgent("qoder", "Qoder", "/HOME/.qoder/skills", ["/HOME/.qoder"]),
        SkillAgent("qoder-cn", "Qoder CN", "/HOME/.qoder-cn/skills", ["/HOME/.qoder-cn"]),
        SkillAgent("qwen-code", "Qwen Code", "/HOME/.qwen/skills", ["/HOME/.qwen"]),
        SkillAgent("replit", "Replit", "/CONFIG/agents/skills", ["/CONFIG/agents"]),
        SkillAgent("reasonix", "Reasonix", "/HOME/.reasonix/skills", ["/HOME/.reasonix"]),
        SkillAgent("rovodev", "Rovo Dev", "/HOME/.rovodev/skills", ["/HOME/.rovodev"]),
        SkillAgent("roo", "Roo Code", "/HOME/.roo/skills", ["/HOME/.roo"]),
        SkillAgent("tabnine-cli", "Tabnine CLI", "/HOME/.tabnine/agent/skills", ["/HOME/.tabnine"]),
        SkillAgent("terramind", "Terramind", "/HOME/.terramind/skills", ["/HOME/.terramind"]),
        SkillAgent("tinycloud", "Tinycloud", "/HOME/.tinycloud/skills", ["/HOME/.tinycloud"]),
        SkillAgent("trae", "Trae", "/HOME/.trae/skills", ["/HOME/.trae"]),
        SkillAgent("trae-cn", "Trae CN", "/HOME/.trae-cn/skills", ["/HOME/.trae-cn"]),
        SkillAgent("warp", "Warp", "/HOME/.agents/skills", ["/HOME/.warp"]),
        SkillAgent(
            "windsurf", "Windsurf", "/HOME/.codeium/windsurf/skills", ["/HOME/.codeium/windsurf"]),
        SkillAgent("zed", "Zed", "/HOME/.agents/skills", ["/CONFIG/zed"]),
        SkillAgent(
            "zcode", "ZCode", "/HOME/.zcode/skills", ["/HOME/.zcode", "/Applications/ZCode.app"]),
        SkillAgent("zencoder", "Zencoder", "/HOME/.zencoder/skills", ["/HOME/.zencoder"]),
        SkillAgent("zenflow", "Zenflow", "/HOME/.zencoder/skills", ["/HOME/.zencoder"]),
        SkillAgent("neovate", "Neovate", "/HOME/.neovate/skills", ["/HOME/.neovate"]),
        SkillAgent("pochi", "Pochi", "/HOME/.pochi/skills", ["/HOME/.pochi"]),
        SkillAgent("adal", "AdaL", "/HOME/.adal/skills", ["/HOME/.adal"]),
    ]
}
