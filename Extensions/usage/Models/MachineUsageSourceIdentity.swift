import Foundation

public enum MachineUsageSourceIdentity {
    public static func canonical(machineID: String, source: String) -> String? {
        let machine = machineID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base =
            source.split(separator: ":", omittingEmptySubsequences: false).last?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !machine.isEmpty, !base.isEmpty else { return nil }
        return "machine:\(machine):\(base)"
    }
}
