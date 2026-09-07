import AppKit

@MainActor public enum SkillBrand {
    private static var menuImages: [String: NSImage] = [:]
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

    public static func menuImage(for id: String) -> NSImage? {
        if let image = menuImages[id] { return image }
        guard let source = image(for: id), source.size.width > 0, source.size.height > 0 else {
            return nil
        }
        let size = NSSize(width: 16, height: 16)
        let scale = min(size.width / source.size.width, size.height / source.size.height)
        let fitted = NSSize(width: source.size.width * scale, height: source.size.height * scale)
        let image = NSImage(size: size, flipped: false) { bounds in
            source.draw(
                in: NSRect(
                    x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
                    width: fitted.width, height: fitted.height))
            return true
        }
        image.isTemplate = source.isTemplate
        menuImages[id] = image
        return image
    }

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
