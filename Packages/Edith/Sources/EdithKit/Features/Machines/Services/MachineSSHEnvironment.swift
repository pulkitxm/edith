import Foundation

public enum MachineSSHEnvironment {
    public static func make(for machine: Machine) -> [String: String] {
        var env = CLIToolEnvironment.sanitized()
        guard machine.auth.usesAskpass else { return env }
        let kind: MachineSecretKind = machine.auth == .password ? .password : .passphrase
        env["SSH_ASKPASS"] = AskpassEntry.helperPath()
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["EDITH_ASKPASS_ACCOUNT"] = MachineSecrets.account(machineID: machine.id, kind: kind)
        return env
    }
}
