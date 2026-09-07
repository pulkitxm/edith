import EdithKit

public enum ClipboardCLIEnvironment {
    nonisolated(unsafe) public static var client = AgentClipboardClient()
    public static func reset() { client = AgentClipboardClient() }
}
