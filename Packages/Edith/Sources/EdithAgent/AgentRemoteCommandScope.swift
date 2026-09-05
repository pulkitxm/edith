import EdithKit
import Foundation

struct AgentRemoteCommandScope: Sendable {
    private static let wrapper =
        "\"${SHELL:-/bin/sh}\" -c \"$2\" <&0 & child=$!; wait \"$child\"; exit $?"

    private static let cleanup = """
        groups=$(ps -ww -eo pid=,pgid=,args= | awk -v prefix="$1" -v self="$$" '
        $1 == $2 && $1 != self {
            row=$0
            sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "", row)
            if (index(row, prefix) == 1) print $1
        }')
        for group in $groups; do printf 'matched:%s\\n' "$group"; done
        for group in $groups; do kill -TERM -- -"$group" 2>/dev/null || :; done
        sleep 0.1
        for group in $groups; do kill -KILL -- -"$group" 2>/dev/null || :; done
        """

    let command: String
    let cleanupCommand: String

    init(command: String, id: UUID = UUID()) {
        let token = id.uuidString
        self.command =
            "exec sh -c \(ShellQuote.quote(Self.wrapper)) edith-machine-command "
            + "\(token) \(ShellQuote.quote(command))"
        let prefix = "sh -c \(Self.wrapper) edith-machine-command \(token) "
        cleanupCommand =
            "exec sh -c \(ShellQuote.quote(Self.cleanup)) edith-machine-cleanup "
            + ShellQuote.quote(prefix)
    }
}
