import EdithExtensionSupport
import Foundation

public enum AskpassEntry {
    public static let accountVariable = "EDITH_ASKPASS_ACCOUNT"

    public static func helperPath() -> String {
        let file = MachinePaths.dir.appendingPathComponent("askpass.sh")
        let script = """
            #!/bin/sh
            case "$1" in
                *yes/no*|*"Are you sure"*) exit 1 ;;
            esac
            exec /usr/bin/security find-generic-password -s \(ShellQuote.quote(MachineSecrets.service)) -a "$EDITH_ASKPASS_ACCOUNT" -w
            """
        MachinePaths.prepare()
        do {
            try Data((script + "\n").utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: file.path)
            return file.path
        } catch { return "/usr/bin/false" }
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
