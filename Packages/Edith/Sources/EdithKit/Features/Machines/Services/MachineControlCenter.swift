import Foundation

public struct MachineControlSnapshot: Equatable, Sendable {
    public var brightness: Int?
    public var volume: Int?
    public var keyboardBacklight: Int?
    public var muted: Bool?
    public var wifiEnabled: Bool?
    public var bluetoothEnabled: Bool?
    public var airplaneMode: Bool?
    public var doNotDisturb: Bool?

    public init(
        brightness: Int? = nil,
        volume: Int? = nil,
        keyboardBacklight: Int? = nil,
        muted: Bool? = nil,
        wifiEnabled: Bool? = nil,
        bluetoothEnabled: Bool? = nil,
        airplaneMode: Bool? = nil,
        doNotDisturb: Bool? = nil
    ) {
        self.brightness = brightness
        self.volume = volume
        self.keyboardBacklight = keyboardBacklight
        self.muted = muted
        self.wifiEnabled = wifiEnabled
        self.bluetoothEnabled = bluetoothEnabled
        self.airplaneMode = airplaneMode
        self.doNotDisturb = doNotDisturb
    }

    public var isEmpty: Bool {
        brightness == nil && volume == nil && keyboardBacklight == nil && muted == nil
            && wifiEnabled == nil && bluetoothEnabled == nil && airplaneMode == nil
            && doNotDisturb == nil
    }
}

public enum MachineControlAction: Equatable, Sendable {
    case setBrightness(Int)
    case setVolume(Int)
    case setKeyboardBacklight(Int)
    case setMuted(Bool)
    case setWiFiEnabled(Bool)
    case setBluetoothEnabled(Bool)
    case setAirplaneMode(Bool)
    case setDoNotDisturb(Bool)
}

public enum MachineControlCenterCommands {
    public static let statusCommand = """
        export LC_ALL=C

        emit_level() {
            case "$2" in
                ''|*[!0-9]*) return ;;
            esac
            [ "$2" -ge 0 ] 2>/dev/null || return
            [ "$2" -le 100 ] 2>/dev/null || return
            printf 'EDITH_CONTROL_%s=%s\n' "$1" "$2"
        }

        emit_bool() {
            case "$2" in
                0|1) printf 'EDITH_CONTROL_%s=%s\n' "$1" "$2" ;;
            esac
        }

        fraction_to_level() {
            awk -v raw="$1" 'BEGIN {
                if (raw !~ /^[0-9]+([.][0-9]+)?$/) exit 1
                value = raw + 0
                if (value < 0) exit 1
                level = int(value * 100 + 0.5)
                if (level > 100) level = 100
                print level
            }'
        }

        prepare_linux_desktop() {
            uid=$(id -u 2>/dev/null || true)
            case "$uid" in
                ''|*[!0-9]*) return ;;
            esac
            if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -d "/run/user/$uid" ]; then
                XDG_RUNTIME_DIR="/run/user/$uid"
                export XDG_RUNTIME_DIR
            fi
            if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -S "$XDG_RUNTIME_DIR/bus" ]; then
                DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
                export DBUS_SESSION_BUS_ADDRESS
            fi
        }

        platform=$(uname -s 2>/dev/null || true)

        if [ "$platform" = Linux ]; then
            prepare_linux_desktop

            brightness_done=0
            if command -v brightnessctl >/dev/null 2>&1; then
                current=$(brightnessctl -c backlight get 2>/dev/null || true)
                maximum=$(brightnessctl -c backlight max 2>/dev/null || true)
                case "$current:$maximum" in
                    *[!0-9:]*|:*|*:) ;;
                    *)
                        if [ "$maximum" -gt 0 ] 2>/dev/null; then
                            level=$(((current * 100 + maximum / 2) / maximum))
                            [ "$level" -gt 100 ] && level=100
                            emit_level BRIGHTNESS "$level"
                            brightness_done=1
                        fi
                        ;;
                esac
            fi
            if [ "$brightness_done" -eq 0 ]; then
                for backlight in /sys/class/backlight/*; do
                    [ -d "$backlight" ] || continue
                    current=$(cat "$backlight/brightness" 2>/dev/null || true)
                    maximum=$(cat "$backlight/max_brightness" 2>/dev/null || true)
                    case "$current:$maximum" in
                        *[!0-9:]*|:*|*:) continue ;;
                    esac
                    [ "$maximum" -gt 0 ] 2>/dev/null || continue
                    level=$(((current * 100 + maximum / 2) / maximum))
                    [ "$level" -gt 100 ] && level=100
                    emit_level BRIGHTNESS "$level"
                    break
                done
            fi

            audio_done=0
            if command -v wpctl >/dev/null 2>&1; then
                audio=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null || true)
                fraction=$(printf '%s\n' "$audio" | awk '$1 == "Volume:" { print $2; exit }')
                level=$(fraction_to_level "$fraction" 2>/dev/null || true)
                if [ -n "$level" ]; then
                    emit_level VOLUME "$level"
                    case "$audio" in
                        *'[MUTED]'*) emit_bool MUTED 1 ;;
                        *) emit_bool MUTED 0 ;;
                    esac
                    audio_done=1
                fi
            fi
            if [ "$audio_done" -eq 0 ] && command -v pactl >/dev/null 2>&1; then
                volume_output=$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null || true)
                mute_output=$(pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null || true)
                level=$(printf '%s\n' "$volume_output" | awk '
                    match($0, /[0-9]+%/) { print substr($0, RSTART, RLENGTH - 1); exit }
                ')
                muted=$(printf '%s\n' "$mute_output" | awk '
                    $1 == "Mute:" && $2 == "yes" { print 1; exit }
                    $1 == "Mute:" && $2 == "no" { print 0; exit }
                ')
                if [ -n "$level" ] && [ -n "$muted" ]; then
                    [ "$level" -gt 100 ] 2>/dev/null && level=100
                    emit_level VOLUME "$level"
                    emit_bool MUTED "$muted"
                    audio_done=1
                fi
            fi
            if [ "$audio_done" -eq 0 ] && command -v amixer >/dev/null 2>&1; then
                audio=$(amixer get Master 2>/dev/null || true)
                level=$(printf '%s\n' "$audio" | awk '
                    {
                        for (i = 1; i <= NF; i++) {
                            if ($i ~ /^\\[[0-9]+%\\]$/) {
                                value = $i
                                gsub(/[^0-9]/, "", value)
                                last = value
                            }
                        }
                    }
                    END { if (last != "") print last }
                ')
                muted=$(printf '%s\n' "$audio" | awk '
                    {
                        for (i = 1; i <= NF; i++) {
                            if ($i == "[on]") last = 0
                            if ($i == "[off]") last = 1
                        }
                    }
                    END { if (last != "") print last }
                ')
                if [ -n "$level" ] && [ -n "$muted" ]; then
                    [ "$level" -gt 100 ] 2>/dev/null && level=100
                    emit_level VOLUME "$level"
                    emit_bool MUTED "$muted"
                fi
            fi

            wifi_done=0
            if command -v nmcli >/dev/null 2>&1; then
                wifi=$(nmcli -t -f WIFI general 2>/dev/null || true)
                case "$wifi" in
                    enabled) emit_bool WIFI_ENABLED 1; wifi_done=1 ;;
                    disabled) emit_bool WIFI_ENABLED 0; wifi_done=1 ;;
                esac
            fi
            if [ "$wifi_done" -eq 0 ] && command -v rfkill >/dev/null 2>&1; then
                radio=$(rfkill list wlan 2>/dev/null || true)
                wifi=$(printf '%s\n' "$radio" | awk '
                    $1 == "Soft" && $2 == "blocked:" && $3 == "no" { seen = 1; unblocked = 1 }
                    $1 == "Soft" && $2 == "blocked:" && $3 == "yes" { seen = 1 }
                    END { if (seen) print unblocked ? 1 : 0 }
                ')
                emit_bool WIFI_ENABLED "$wifi"
            fi

            bluetooth_done=0
            if command -v bluetoothctl >/dev/null 2>&1; then
                bluetooth=$(bluetoothctl show 2>/dev/null | awk '
                    $1 == "Powered:" && $2 == "yes" { print 1; exit }
                    $1 == "Powered:" && $2 == "no" { print 0; exit }
                ')
                if [ -n "$bluetooth" ]; then
                    emit_bool BLUETOOTH_ENABLED "$bluetooth"
                    bluetooth_done=1
                fi
            fi
            if [ "$bluetooth_done" -eq 0 ] && command -v rfkill >/dev/null 2>&1; then
                radio=$(rfkill list bluetooth 2>/dev/null || true)
                bluetooth=$(printf '%s\n' "$radio" | awk '
                    $1 == "Soft" && $2 == "blocked:" && $3 == "no" { seen = 1; unblocked = 1 }
                    $1 == "Soft" && $2 == "blocked:" && $3 == "yes" { seen = 1 }
                    END { if (seen) print unblocked ? 1 : 0 }
                ')
                emit_bool BLUETOOTH_ENABLED "$bluetooth"
            fi

            keyboard_path=
            for candidate in /sys/class/leds/*; do
                [ -d "$candidate" ] || continue
                keyboard_name=${candidate##*/}
                case "$keyboard_name" in
                    *kbd_backlight*|*kbd-backlight*|*keyboard_backlight*|*keyboard-backlight*)
                        keyboard_path=$candidate
                        break
                        ;;
                esac
            done
            if [ -n "$keyboard_path" ]; then
                keyboard_done=0
                if command -v brightnessctl >/dev/null 2>&1; then
                    current=$(brightnessctl -d "$keyboard_name" get 2>/dev/null || true)
                    maximum=$(brightnessctl -d "$keyboard_name" max 2>/dev/null || true)
                    case "$current:$maximum" in
                        *[!0-9:]*|:*|*:) ;;
                        *)
                            if [ "$maximum" -gt 0 ] 2>/dev/null; then
                                level=$(((current * 100 + maximum / 2) / maximum))
                                [ "$level" -gt 100 ] && level=100
                                emit_level KEYBOARD_BACKLIGHT "$level"
                                keyboard_done=1
                            fi
                            ;;
                    esac
                fi
                if [ "$keyboard_done" -eq 0 ]; then
                    current=$(cat "$keyboard_path/brightness" 2>/dev/null || true)
                    maximum=$(cat "$keyboard_path/max_brightness" 2>/dev/null || true)
                    case "$current:$maximum" in
                        *[!0-9:]*|:*|*:) ;;
                        *)
                            if [ "$maximum" -gt 0 ] 2>/dev/null; then
                                level=$(((current * 100 + maximum / 2) / maximum))
                                [ "$level" -gt 100 ] && level=100
                                emit_level KEYBOARD_BACKLIGHT "$level"
                            fi
                            ;;
                    esac
                fi
            fi

            if command -v rfkill >/dev/null 2>&1; then
                radios=$(rfkill list 2>/dev/null || true)
                airplane=$(printf '%s\n' "$radios" | awk '
                    $1 == "Soft" && $2 == "blocked:" && $3 == "yes" { seen = 1 }
                    $1 == "Soft" && $2 == "blocked:" && $3 == "no" { seen = 1; unblocked = 1 }
                    END { if (seen) print unblocked ? 0 : 1 }
                ')
                emit_bool AIRPLANE_MODE "$airplane"
            fi

            if command -v gsettings >/dev/null 2>&1; then
                banners=$(gsettings get org.gnome.desktop.notifications show-banners 2>/dev/null || true)
                case "$banners" in
                    true) emit_bool DO_NOT_DISTURB 0 ;;
                    false) emit_bool DO_NOT_DISTURB 1 ;;
                esac
            fi
        elif [ "$platform" = Darwin ]; then
            if command -v brightness >/dev/null 2>&1; then
                fraction=$(brightness -l 2>/dev/null | awk '
                    $0 ~ /brightness [0-9]+([.][0-9]+)?$/ { print $NF; exit }
                ')
                level=$(fraction_to_level "$fraction" 2>/dev/null || true)
                emit_level BRIGHTNESS "$level"
            fi

            if command -v osascript >/dev/null 2>&1; then
                level=$(osascript -e 'output volume of (get volume settings)' 2>/dev/null || true)
                muted=$(osascript -e 'output muted of (get volume settings)' 2>/dev/null || true)
                case "$level" in
                    ''|*[!0-9]*) ;;
                    *) emit_level VOLUME "$level" ;;
                esac
                case "$muted" in
                    true) emit_bool MUTED 1 ;;
                    false) emit_bool MUTED 0 ;;
                esac
            fi

            if command -v networksetup >/dev/null 2>&1; then
                wifi_device=$(networksetup -listallhardwareports 2>/dev/null | awk '
                    $0 == "Hardware Port: Wi-Fi" || $0 == "Hardware Port: AirPort" {
                        if (getline > 0 && $1 == "Device:") print $2
                        exit
                    }
                ')
                case "$wifi_device" in
                    ''|*[!A-Za-z0-9._-]*) ;;
                    *)
                        wifi=$(networksetup -getairportpower "$wifi_device" 2>/dev/null | awk '
                            $NF == "On" { print 1; exit }
                            $NF == "Off" { print 0; exit }
                        ')
                        emit_bool WIFI_ENABLED "$wifi"
                        ;;
                esac
            fi

            if command -v blueutil >/dev/null 2>&1; then
                bluetooth=$(blueutil -p 2>/dev/null || true)
                emit_bool BLUETOOTH_ENABLED "$bluetooth"
            fi

            if command -v mac-brightnessctl >/dev/null 2>&1; then
                keyboard_output=$(mac-brightnessctl 2>/dev/null || true)
                fraction=$(printf '%s\n' "$keyboard_output" | awk '
                    $1 == "Current" && $2 == "brightness:" && NF == 3 { print $3; exit }
                ')
                level=$(fraction_to_level "$fraction" 2>/dev/null || true)
                emit_level KEYBOARD_BACKLIGHT "$level"
            fi
        fi
        """

    public static func parseStatus(_ output: String) -> MachineControlSnapshot {
        var snapshot = MachineControlSnapshot()

        for line in output.split(whereSeparator: \Character.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0]
            let value = String(parts[1])

            switch key {
            case "EDITH_CONTROL_BRIGHTNESS":
                if let parsed = level(value) { snapshot.brightness = parsed }
            case "EDITH_CONTROL_VOLUME":
                if let parsed = level(value) { snapshot.volume = parsed }
            case "EDITH_CONTROL_KEYBOARD_BACKLIGHT":
                if let parsed = level(value) { snapshot.keyboardBacklight = parsed }
            case "EDITH_CONTROL_MUTED":
                if let parsed = flag(value) { snapshot.muted = parsed }
            case "EDITH_CONTROL_WIFI_ENABLED":
                if let parsed = flag(value) { snapshot.wifiEnabled = parsed }
            case "EDITH_CONTROL_BLUETOOTH_ENABLED":
                if let parsed = flag(value) { snapshot.bluetoothEnabled = parsed }
            case "EDITH_CONTROL_AIRPLANE_MODE":
                if let parsed = flag(value) { snapshot.airplaneMode = parsed }
            case "EDITH_CONTROL_DO_NOT_DISTURB":
                if let parsed = flag(value) { snapshot.doNotDisturb = parsed }
            default:
                continue
            }
        }

        return snapshot
    }

    public static func command(
        for action: MachineControlAction, withSudoPassword: Bool
    ) -> String {
        let sudoCommand = withSudoPassword ? "sudo -S -p ''" : "sudo -n"
        let linux: String
        let darwin: String

        switch action {
        case .setBrightness(let requested):
            let value = clamped(requested)
            linux = """
                level=\(value)
                if command -v brightnessctl >/dev/null 2>&1 && brightnessctl -c backlight set "${level}%" >/dev/null 2>&1; then
                    exit 0
                fi
                for backlight in /sys/class/backlight/*; do
                    [ -d "$backlight" ] || continue
                    maximum=$(cat "$backlight/max_brightness" 2>/dev/null || true)
                    case "$maximum" in
                        ''|*[!0-9]*) continue ;;
                    esac
                    [ "$maximum" -gt 0 ] 2>/dev/null || continue
                    raw=$(((level * maximum + 50) / 100))
                    \(sudoCommand) sh -c 'printf "%s\\n" "$1" > "$2"' sh "$raw" "$backlight/brightness" >/dev/null 2>&1 && exit 0
                done
                exit 4
                """
            darwin = """
                command -v brightness >/dev/null 2>&1 || exit 4
                brightness \(Double(value) / 100) >/dev/null 2>&1
                """
        case .setVolume(let requested):
            let value = clamped(requested)
            linux = """
                level=\(value)
                if command -v wpctl >/dev/null 2>&1 && wpctl set-volume @DEFAULT_AUDIO_SINK@ "${level}%" >/dev/null 2>&1; then
                    exit 0
                fi
                if command -v pactl >/dev/null 2>&1 && pactl set-sink-volume @DEFAULT_SINK@ "${level}%" >/dev/null 2>&1; then
                    exit 0
                fi
                if command -v amixer >/dev/null 2>&1 && amixer set Master "${level}%" >/dev/null 2>&1; then
                    exit 0
                fi
                exit 4
                """
            darwin = """
                command -v osascript >/dev/null 2>&1 || exit 4
                osascript -e 'set volume output volume \(value)' >/dev/null 2>&1
                """
        case .setKeyboardBacklight(let requested):
            let value = clamped(requested)
            linux = """
                level=\(value)
                for keyboard_path in /sys/class/leds/*; do
                    [ -d "$keyboard_path" ] || continue
                    keyboard_name=${keyboard_path##*/}
                    case "$keyboard_name" in
                        *kbd_backlight*|*kbd-backlight*|*keyboard_backlight*|*keyboard-backlight*) ;;
                        *) continue ;;
                    esac
                    if command -v brightnessctl >/dev/null 2>&1 && brightnessctl -d "$keyboard_name" set "${level}%" >/dev/null 2>&1; then
                        exit 0
                    fi
                    maximum=$(cat "$keyboard_path/max_brightness" 2>/dev/null || true)
                    case "$maximum" in
                        ''|*[!0-9]*) continue ;;
                    esac
                    [ "$maximum" -gt 0 ] 2>/dev/null || continue
                    raw=$(((level * maximum + 50) / 100))
                    \(sudoCommand) sh -c 'printf "%s\\n" "$1" > "$2"' sh "$raw" "$keyboard_path/brightness" >/dev/null 2>&1 && exit 0
                done
                exit 4
                """
            darwin = """
                command -v mac-brightnessctl >/dev/null 2>&1 || exit 4
                mac-brightnessctl \(Double(value) / 100) >/dev/null 2>&1
                """
        case .setMuted(let muted):
            let wpctlValue = muted ? "1" : "0"
            let amixerValue = muted ? "mute" : "unmute"
            let osascriptValue = muted ? "true" : "false"
            linux = """
                if command -v wpctl >/dev/null 2>&1 && wpctl set-mute @DEFAULT_AUDIO_SINK@ \(wpctlValue) >/dev/null 2>&1; then
                    exit 0
                fi
                if command -v pactl >/dev/null 2>&1 && pactl set-sink-mute @DEFAULT_SINK@ \(wpctlValue) >/dev/null 2>&1; then
                    exit 0
                fi
                if command -v amixer >/dev/null 2>&1 && amixer set Master \(amixerValue) >/dev/null 2>&1; then
                    exit 0
                fi
                exit 4
                """
            darwin = """
                command -v osascript >/dev/null 2>&1 || exit 4
                osascript -e 'set volume output muted \(osascriptValue)' >/dev/null 2>&1
                """
        case .setWiFiEnabled(let enabled):
            let nmcliValue = enabled ? "on" : "off"
            let rfkillValue = enabled ? "unblock" : "block"
            linux = """
                if command -v nmcli >/dev/null 2>&1 && nmcli radio wifi \(nmcliValue) >/dev/null 2>&1; then
                    exit 0
                fi
                command -v rfkill >/dev/null 2>&1 || exit 4
                \(sudoCommand) rfkill \(rfkillValue) wlan >/dev/null 2>&1
                """
            darwin = """
                command -v networksetup >/dev/null 2>&1 || exit 4
                wifi_device=$(networksetup -listallhardwareports 2>/dev/null | awk '
                    $0 == "Hardware Port: Wi-Fi" || $0 == "Hardware Port: AirPort" {
                        if (getline > 0 && $1 == "Device:") print $2
                        exit
                    }
                ')
                case "$wifi_device" in
                    ''|*[!A-Za-z0-9._-]*) exit 4 ;;
                esac
                networksetup -setairportpower "$wifi_device" \(nmcliValue) >/dev/null 2>&1
                """
        case .setBluetoothEnabled(let enabled):
            let bluetoothctlValue = enabled ? "on" : "off"
            let blueutilValue = enabled ? "1" : "0"
            let rfkillValue = enabled ? "unblock" : "block"
            linux = """
                if command -v bluetoothctl >/dev/null 2>&1 && bluetoothctl power \(bluetoothctlValue) >/dev/null 2>&1; then
                    exit 0
                fi
                command -v rfkill >/dev/null 2>&1 || exit 4
                \(sudoCommand) rfkill \(rfkillValue) bluetooth >/dev/null 2>&1
                """
            darwin = """
                command -v blueutil >/dev/null 2>&1 || exit 4
                blueutil -p \(blueutilValue) >/dev/null 2>&1
                """
        case .setAirplaneMode(let enabled):
            let rfkillValue = enabled ? "block" : "unblock"
            linux = """
                command -v rfkill >/dev/null 2>&1 || exit 4
                \(sudoCommand) rfkill \(rfkillValue) all >/dev/null 2>&1
                """
            darwin = "exit 4"
        case .setDoNotDisturb(let enabled):
            let banners = enabled ? "false" : "true"
            linux = """
                command -v gsettings >/dev/null 2>&1 || exit 4
                gsettings set org.gnome.desktop.notifications show-banners \(banners) >/dev/null 2>&1
                """
            darwin = "exit 4"
        }

        return platformCommand(linux: linux, darwin: darwin)
    }

    private static func clamped(_ value: Int) -> Int {
        min(max(value, 0), 100)
    }

    private static func level(_ value: String) -> Int? {
        guard let parsed = Int(value), (0...100).contains(parsed) else { return nil }
        return parsed
    }

    private static func flag(_ value: String) -> Bool? {
        switch value {
        case "0": false
        case "1": true
        default: nil
        }
    }

    private static func platformCommand(linux: String, darwin: String) -> String {
        """
        export LC_ALL=C
        platform=$(uname -s 2>/dev/null || true)
        if [ "$platform" = Linux ]; then
            uid=$(id -u 2>/dev/null || true)
            case "$uid" in
                ''|*[!0-9]*) ;;
                *)
                    if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -d "/run/user/$uid" ]; then
                        XDG_RUNTIME_DIR="/run/user/$uid"
                        export XDG_RUNTIME_DIR
                    fi
                    if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -S "$XDG_RUNTIME_DIR/bus" ]; then
                        DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
                        export DBUS_SESSION_BUS_ADDRESS
                    fi
                    ;;
            esac
        \(linux)
        elif [ "$platform" = Darwin ]; then
        \(darwin)
        else
            exit 4
        fi
        """
    }
}
