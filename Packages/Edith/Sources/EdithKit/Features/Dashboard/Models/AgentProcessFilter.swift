public enum AgentProcessFilter {
    public static let matchNames: Set<String> = [
        "claude", "node", "bun", "npm", "npx", "deno", "python", "python3", "tsx", "ts-node",
    ]

    public static func isAgentProcess(name: String) -> Bool {
        matchNames.contains(name.lowercased())
    }
}
