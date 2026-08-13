import Foundation

public enum MachineProfileDuration: Int, CaseIterable, Sendable {
    case untilChanged = 0
    case fifteenMinutes = 900
    case thirtyMinutes = 1_800
    case oneHour = 3_600
    case twoHours = 7_200

    public var label: String {
        switch self {
        case .untilChanged: "Until changed"
        case .fifteenMinutes: "15 minutes"
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 hour"
        case .twoHours: "2 hours"
        }
    }
}

public enum MachineThermalControls {
    public static let profilePath = "/sys/firmware/acpi/platform_profile"
    public static let choicesPath = "/sys/firmware/acpi/platform_profile_choices"
    public static let revertUnit = "edith-platform-profile-revert"

    public static let statusCommand = """
        path=\(profilePath)
        choices=\(choicesPath)
        [ -r "$path" ] && [ -r "$choices" ] || exit 4
        printf '%s\n' "$(cat "$path")"
        cat "$choices"
        """

    public static func validProfile(_ profile: String) -> Bool {
        !profile.isEmpty
            && profile.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
            }
    }

    public static func parseStatus(_ output: String) -> MachinePlatformProfile? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        guard let current = lines.first.map(String.init), validProfile(current) else { return nil }
        let choices = lines.dropFirst().joined(separator: " ").split(
            whereSeparator: \Character.isWhitespace
        )
        .map(String.init).filter(validProfile)
        guard !choices.isEmpty, choices.contains(current) else { return nil }
        return MachinePlatformProfile(current: current, choices: choices)
    }

    public static func setProfile(
        _ profile: String, duration: MachineProfileDuration, withSudoPassword: Bool
    ) -> String? {
        setProfile(
            profile, durationSeconds: duration.rawValue, withSudoPassword: withSudoPassword)
    }

    public static func setProfile(
        _ profile: String, durationSeconds: Int, withSudoPassword: Bool
    ) -> String? {
        guard validProfile(profile) else { return nil }
        guard durationSeconds >= 0 else { return nil }
        let seconds = durationSeconds
        let path = ShellQuote.quote(profilePath)
        let state = ShellQuote.quote("/run/edith-platform-profile-original")
        let unit = ShellQuote.quote(revertUnit)
        let selected = ShellQuote.quote(profile)
        let action: String
        if seconds > 0 {
            action = """
                command -v systemd-run >/dev/null 2>&1 || { printf '%s\n' 'Timed profiles need systemd-run.' >&2; exit 4; }
                if [ -r "$state" ]; then original=$(cat "$state"); else original=$(cat "$path"); fi
                printf '%s\n' "$original" > "$state"
                printf '%s\n' "$selected" > "$path"
                systemd-run --quiet --unit="$unit" --on-active=\(seconds)s --property=Type=oneshot /bin/sh -c 'if [ "$(cat "$1")" = "$2" ]; then printf "%s\n" "$3" > "$1"; fi; rm -f "$4"' sh "$path" "$selected" "$original" "$state" || { printf '%s\n' "$original" > "$path"; rm -f "$state"; exit 1; }
                """
        } else {
            action = """
                rm -f "$state"
                printf '%s\n' "$selected" > "$path"
                """
        }
        let script = """
            path=\(path)
            state=\(state)
            unit=\(unit)
            selected=\(selected)
            [ -e "$path" ] || { printf '%s\n' 'Platform profiles are not available.' >&2; exit 4; }
            [ -w "$path" ] || { printf '%s\n' 'Platform profile control needs sudo.' >&2; exit 1; }
            systemctl stop "$unit.timer" "$unit.service" >/dev/null 2>&1 || true
            systemctl reset-failed "$unit.timer" "$unit.service" >/dev/null 2>&1 || true
            \(action)
            printf '%s\n' "$selected"
            """
        let quoted = ShellQuote.quote(script)
        if withSudoPassword {
            return "sudo -S -p '' sh -c \(quoted) 2>&1"
        }
        return "if [ -w \(path) ]; then sh -c \(quoted); else sudo -n sh -c \(quoted); fi 2>&1"
    }
}
