import AppKit

@MainActor public enum SkillBrand {
    private static var images: [String: NSImage] = [:]
    private static let names = [
        "amp": "amp", "antigravity": "antigravity", "claude-code": "claude",
        "cline": "cline", "codex": "codex", "github-copilot": "copilot",
        "cursor": "cursor", "devin": "devin", "gemini-cli": "gemini",
        "grok": "grok", "grok-build": "grok", "kimi-code-cli": "kimi",
        "kilo": "kilo", "kiro-cli": "kiro", "opencode": "opencode", "pi": "pi",
        "qoder": "qoder", "qwen-code": "qwen", "command-code": "plugin-command-code",
        "droid": "plugin-droid", "mistral-vibe": "plugin-mistral",
        "warp": "plugin-warp", "zed": "plugin-zed",
    ]

    public static func image(for id: String) -> NSImage? {
        if let image = images[id] { return image }
        guard let name = names[id] else { return nil }
        let image: NSImage?
        if name.hasPrefix("plugin-") {
            image = Bundle.module.url(forResource: name, withExtension: "svg")
                .flatMap(NSImage.init(contentsOf:))
            image?.isTemplate = ["command-code", "zed"].contains(id)
        } else {
            image = ProviderLogo.image(named: name)
        }
        images[id] = image
        return image
    }
}
