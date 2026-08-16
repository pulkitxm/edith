import Foundation

public struct MachineSessionSummary: Equatable, Sendable {
    public var who: [String]
    public var updatesAvailable: Int?
    public var macAddress: String?

    public init(who: [String] = [], updatesAvailable: Int? = nil, macAddress: String? = nil) {
        self.who = who
        self.updatesAvailable = updatesAvailable
        self.macAddress = macAddress
    }
}

public enum MachineFacts {
    public static let whoCommand = "who 2>/dev/null | head -20"

    public static let macAddressCommand = """
        networksetup -listallhardwareports 2>/dev/null | awk '
          /^Hardware Port: (Ethernet|Wi-Fi)$/ { wanted=1; next }
          wanted && /^Ethernet Address:/ { print $3; exit }
          /^Hardware Port:/ { wanted=0 }
        '
        """

    public static let updatesCommand = """
        softwareupdate -l 2>/dev/null | awk '/^[[:space:]]*\\* Label:/ { count++ } END { print count + 0 }'
        """

    public static func parseWho(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3 else { return nil }
            let user = String(parts[0])
            let tty = String(parts[1])
            let rest = parts.dropFirst(2).joined(separator: " ")
            return "\(user) on \(tty) since \(rest)"
        }
    }

    public static func parseUpdates(_ output: String) -> Int? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value >= 0 else { return nil }
        return value
    }

    public static func parseMACAddress(_ output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$"
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return trimmed.lowercased()
    }
}

public enum PowerCommands {
    public static func reboot(withSudoPassword: Bool = false) -> String {
        withSudoPassword
            ? "sudo -S -p '' shutdown -r now 2>&1"
            : "sudo -n shutdown -r now 2>&1"
    }

    public static func shutdown(withSudoPassword: Bool = false) -> String {
        withSudoPassword
            ? "sudo -S -p '' shutdown -h now 2>&1"
            : "sudo -n shutdown -h now 2>&1"
    }
}

public enum ProcessCommands {
    public static let signals = ["TERM", "KILL", "HUP", "INT", "QUIT", "USR1", "USR2"]

    public static let goneMarker = "@EDITH-PROCESS-GONE@"

    public static func kill(pid: Int, signal: String) -> String {
        "if kill -0 \(pid) 2>/dev/null; then "
            + "kill -\(signal) \(pid) 2>&1; else echo \(goneMarker); fi"
    }

    public static func hadAlreadyExited(_ output: String) -> Bool {
        output.contains(goneMarker)
    }

    public static func normalizedSignal(_ raw: String) -> String? {
        let name =
            raw.uppercased().hasPrefix("SIG")
            ? String(raw.uppercased().dropFirst(3)) : raw.uppercased()
        return signals.contains(name) ? name : nil
    }
}

public enum PowerOutcome {
    public static func hostWentAway(_ error: Error) -> Bool {
        guard case let SSHConnectionError.commandFailed(_, status, stderr) = error else {
            return false
        }
        guard status != 255 else { return true }
        let text = stderr.lowercased()
        return text.contains("connection closed") || text.contains("closed by remote host")
            || text.contains("connection reset")
    }

    public static func needsPrivilege(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("password is required")
            || lowered.contains("interactive authentication required")
            || lowered.contains("access denied")
            || lowered.contains("not authorized")
            || lowered.contains("permission denied")
    }

    public static func sudoPasswordRefused(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("incorrect password attempt")
            || lowered.contains("sorry, try again")
    }

    public static func explain(_ error: Error) -> String {
        let text = error.localizedDescription
        let detail =
            text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .last ?? ""
        guard !detail.isEmpty else { return "The machine refused the request." }
        guard !sudoPasswordRefused(text) else {
            return "The sudo password saved for this machine was refused."
        }
        guard needsPrivilege(detail) else { return detail }
        return detail
            + " Save this account's sudo password in the machine's settings."
    }
}

public enum WakeOnLAN {
    public static func magicPacket(macAddress: String) -> Data? {
        let hex = macAddress.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard hex.count == 6 else { return nil }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: hex) }
        return packet
    }
}

public enum MagicPacket {
    public static func send(_ packet: Data) -> String? {
        let handle = socket(AF_INET, SOCK_DGRAM, 0)
        guard handle >= 0 else { return "Could not open a socket." }
        defer { close(handle) }
        var broadcast: Int32 = 1
        setsockopt(
            handle, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(9).bigEndian
        address.sin_addr.s_addr = INADDR_BROADCAST
        let sent = packet.withUnsafeBytes { buffer -> Int in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    sendto(
                        handle, buffer.baseAddress, buffer.count, 0, sockaddrPointer,
                        socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent > 0 ? nil : "The wake packet could not be sent."
    }
}
