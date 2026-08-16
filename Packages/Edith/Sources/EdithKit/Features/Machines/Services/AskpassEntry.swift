import Foundation

public enum AskpassEntry {
    public static let accountVariable = "EDITH_ASKPASS_ACCOUNT"

    public static func helperPath() -> String {
        Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments.first ?? ""
    }

    public static func runIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let account = environment[accountVariable], !account.isEmpty else { return false }
        let prompt = arguments.dropFirst().first ?? ""
        if isConfirmationPrompt(prompt) {
            exit(1)
        }
        guard let secret = MachineSecrets.get(account: account) else {
            exit(1)
        }
        FileHandle.standardOutput.write(Data((secret + "\n").utf8))
        exit(0)
    }

    static func isConfirmationPrompt(_ prompt: String) -> Bool {
        let lowered = prompt.lowercased()
        return lowered.contains("(yes/no") || lowered.contains("are you sure")
    }
}
