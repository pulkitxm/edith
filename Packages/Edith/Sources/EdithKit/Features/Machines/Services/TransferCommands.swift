import Foundation

public enum TransferEndpoint: Hashable, Sendable {
    case localMac
    case machine(UUID)
}

public enum TransferOperation: String, Equatable, Sendable {
    case copy
    case move

    public var verb: String {
        switch self {
        case .copy: return "Copying"
        case .move: return "Moving"
        }
    }
}

public enum TransferRoute: Equatable, Sendable {
    case localFile
    case remoteLocal(UUID)
    case push(UUID)
    case pull(UUID)
    case relay(from: UUID, to: UUID)

    public static func route(from source: TransferEndpoint, to destination: TransferEndpoint)
        -> TransferRoute
    {
        switch (source, destination) {
        case (.localMac, .localMac):
            return .localFile
        case let (.machine(a), .machine(b)):
            return a == b ? .remoteLocal(a) : .relay(from: a, to: b)
        case let (.localMac, .machine(b)):
            return .push(b)
        case let (.machine(a), .localMac):
            return .pull(a)
        }
    }
}

public enum TransferTier: String, Equatable, Sendable {
    case rsyncProgress2
    case rsyncClassic
    case tarPipe
    case verboseCopy
}

public struct MachineTransferFacts: Equatable, Sendable {
    public enum RsyncFlavour: Equatable, Sendable {
        case none
        case openrsync
        case gnu(major: Int, minor: Int)
    }

    public var rsync: RsyncFlavour
    public var hasPv: Bool
    public var findSupportsPrintf: Bool
    public var isRoot: Bool

    public init(
        rsync: RsyncFlavour = .none, hasPv: Bool = false, findSupportsPrintf: Bool = false,
        isRoot: Bool = false
    ) {
        self.rsync = rsync
        self.hasPv = hasPv
        self.findSupportsPrintf = findSupportsPrintf
        self.isRoot = isRoot
    }

    public var tier: TransferTier {
        switch rsync {
        case .gnu: return .rsyncProgress2
        case .openrsync: return .rsyncClassic
        case .none: return hasPv ? .tarPipe : .verboseCopy
        }
    }

    public static let probeCommand = """
        if command -v rsync >/dev/null 2>&1; then rsync --version 2>/dev/null | head -1 \
        | sed 's/^/rsync=/'; else echo rsync=none; fi
        command -v pv >/dev/null 2>&1 && echo pv=yes || echo pv=no
        find . -maxdepth 0 -printf '' >/dev/null 2>&1 && echo findprintf=yes || echo findprintf=no
        printf 'uid=%s\\n' "$(id -u)"
        """

    public static func parse(_ output: String) -> MachineTransferFacts {
        var facts = MachineTransferFacts()
        for line in output.split(separator: "\n").map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("rsync=") {
                facts.rsync = flavour(String(trimmed.dropFirst(6)))
            } else if trimmed == "pv=yes" {
                facts.hasPv = true
            } else if trimmed == "findprintf=yes" {
                facts.findSupportsPrintf = true
            } else if trimmed.hasPrefix("uid=") {
                facts.isRoot = trimmed.dropFirst(4) == "0"
            }
        }
        return facts
    }

    static func flavour(_ line: String) -> RsyncFlavour {
        let lowered = line.lowercased()
        if lowered.contains("openrsync") { return .openrsync }
        if lowered == "none" || lowered.isEmpty { return .none }
        guard let range = lowered.range(of: "version ") else { return .none }
        let digits = lowered[range.upperBound...].prefix { $0.isNumber || $0 == "." }
        let parts = digits.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return .none }
        return .gnu(major: major, minor: parts.count > 1 ? parts[1] : 0)
    }
}

public enum TransferCommands {
    public static let markerPrefix = "EDITH"
    public static let partialDirectory = ".edith-partial"

    public static func sameFilesystemProbe(source: String, destinationDirectory: String) -> String {
        let a = ShellQuote.quote(source)
        let b = ShellQuote.quote(destinationDirectory)
        return "[ \"$(df -P -- \(a) | awk 'NR==2{print $1}')\" = "
            + "\"$(df -P -- \(b) | awk 'NR==2{print $1}')\" ] && echo same || echo cross"
    }

    public static func scanCommand(paths: [String], gnuFind: Bool) -> String {
        let quoted = paths.map { ShellQuote.quote($0) }.joined(separator: " ")
        let tally = "awk '{n++;b+=$1} END{printf \"\(markerPrefix) SCAN %d %d\\n\", n+0, b+0}'"
        if gnuFind {
            return "find -- \(quoted) \\( -type f -o -type l \\) -printf '%s\\n' | \(tally)"
        }
        return "find -- \(quoted) \\( -type f -o -type l \\) -print0"
            + " | xargs -0 stat -f '%z' | \(tally)"
    }

    public static func copyBody(tier: TransferTier, scanBytes: Int64?) -> String {
        switch tier {
        case .rsyncProgress2:
            return "rsync -aHS --no-inc-recursive --info=progress2"
                + " --partial-dir=\(partialDirectory) --exclude=\(partialDirectory)"
                + " -- \"$s\" \"$t\""
        case .rsyncClassic:
            return "rsync -aHS --progress"
                + " --partial-dir=\(partialDirectory) --exclude=\(partialDirectory)"
                + " -- \"$s\" \"$t\""
        case .tarPipe:
            let size = scanBytes.map { " -s \($0)" } ?? ""
            return "tar -cf - -C \"$(dirname -- \"$s\")\" -- \"$(basename -- \"$s\")\""
                + " | pv -n -b\(size) 2>&3 | tar -xpf - -C \"$(dirname -- \"$t\")\""
        case .verboseCopy:
            return "cp -av -- \"$s\" \"$t\""
        }
    }

    public static func remoteRunner(
        pairs: [(source: String, target: String)], tier: TransferTier, scanBytes: Int64?
    ) -> String {
        var lines: [String] = []
        lines.append("echo \"\(markerPrefix) PID $$\"")
        if tier == .tarPipe { lines.append("exec 3>&1") }
        lines.append("st=0")
        lines.append("copy_one() {")
        lines.append("  s=\"$1\"; t=\"$2\"; i=\"$3\"")
        lines.append("  if [ \"$s\" -ef \"$t\" ]; then echo \"\(markerPrefix) ITEM $i 200\"; ")
        lines.append("    return 0; fi")
        lines.append("  \(copyBody(tier: tier, scanBytes: scanBytes))")
        lines.append("  r=$?")
        lines.append("  echo \"\(markerPrefix) ITEM $i $r\"")
        lines.append("  return $r")
        lines.append("}")
        for (index, pair) in pairs.enumerated() {
            lines.append(
                "copy_one \(ShellQuote.quote(pair.source)) \(ShellQuote.quote(pair.target))"
                    + " \(index) || st=1")
        }
        lines.append("exit $st")
        return lines.joined(separator: "\n")
    }

    public static func signalCommand(pid: Int32, signal: String) -> String {
        "kill -\(signal) -\(pid) 2>/dev/null || kill -\(signal) \(pid) 2>/dev/null || true"
    }

    public static func pause(pid: Int32) -> String { signalCommand(pid: pid, signal: "STOP") }
    public static func resume(pid: Int32) -> String { signalCommand(pid: pid, signal: "CONT") }

    public static func cancel(pid: Int32) -> String {
        signalCommand(pid: pid, signal: "CONT") + "; " + signalCommand(pid: pid, signal: "TERM")
    }

    public static func forceCancel(pid: Int32) -> String {
        signalCommand(pid: pid, signal: "KILL")
    }

    public static func byteCount(path: String) -> String {
        "wc -c < \(ShellQuote.quote(path))"
    }

    public static func resumeRead(path: String, fromByte offset: Int64) -> String {
        guard offset > 0 else { return "cat -- \(ShellQuote.quote(path))" }
        return "tail -c +\(offset + 1) -- \(ShellQuote.quote(path))"
    }

    public static func caseSensitivityProbe(directory: String) -> String {
        let base = ShellQuote.quote(directory)
        return "p=\(base)/.edith-case-probe; rm -f \"$p\" \"$p\"X 2>/dev/null;"
            + " : > \"$p\"; if [ -e \"$(printf '%s' \"$p\" | tr 'a-z' 'A-Z')\" ];"
            + " then echo insensitive; else echo sensitive; fi; rm -f \"$p\" 2>/dev/null"
    }

    public static func finalizeReplacingFile(part: String, target: String) -> String {
        "mv -f \(ShellQuote.quote(part)) \(ShellQuote.quote(target))"
    }

    public static func finalizeReplacingDirectory(part: String, target: String) -> String {
        let quotedTarget = ShellQuote.quote(target)
        let retired = ShellQuote.quote(target + ".edith-old")
        return "mv \(quotedTarget) \(retired) && mv \(ShellQuote.quote(part)) \(quotedTarget)"
            + " && rm -rf \(retired)"
    }
}
