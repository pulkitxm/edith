# `ed machines control`

`ed machines control` exposes the live controls shown in the Machine Control
Center through the same operation definitions and command builder used by the
app. It works against configured SSH machines and against this Mac with the
reserved target `local`.

```sh
ed machines control status box
ed machines control status box --json
ed machines control brightness box 60
ed machines control volume box 35
ed machines control mute box on
ed machines control wifi box off
ed machines control wifi box off --yes
ed machines control bluetooth box on
ed machines control airplane box on --yes
ed machines control dnd box off
ed machines control keyboard-light box 25
ed machines control status local
```

The machine-first form is equivalent:

```sh
ed machines box control status
ed machines box control volume 35
```

## Safety

Turning Wi-Fi off and turning airplane mode on may disconnect an SSH machine.
Those two changes only print a preview unless `--yes` is present. A JSON preview
has `"applied": false`. The confirmed result has `"applied": true`.

Turning Wi-Fi on and turning airplane mode off do not require confirmation.
Brightness, volume and keyboard lighting accept whole numbers from 0 through
100. Mute, Wi-Fi, Bluetooth, airplane mode and Do Not Disturb accept `on` or
`off`.

## Discovery and availability

`status` reports only controls the target can implement. It checks Linux tools
such as `brightnessctl`, `wpctl`, `nmcli`, `bluetoothctl`, `rfkill` and
`gsettings`, plus the matching macOS facilities. A missing control is `null` in
JSON and omitted from the human table. If the target reports no controls at all,
the human command exits 4 with an availability error.

Some Linux controls require a stored sudo password. Edith reads the same
Keychain entry used by the app and passes it on standard input to `sudo -S`.
The password is never placed in arguments or output. Local macOS Wi-Fi changes
use the system authorization prompt.

## JSON

Status returns one object with stable nullable fields:

```json
{
  "airplaneMode": false,
  "batteryLevel": 73,
  "batteryPluggedIn": true,
  "bluetoothEnabled": true,
  "brightness": 61,
  "doNotDisturb": false,
  "keyboardBacklight": 18,
  "local": false,
  "machine": "box",
  "muted": false,
  "platform": "linux",
  "volume": 42,
  "wifiEnabled": true
}
```

Mutations return the machine, whether it is local, the stable operation ID, the
requested value and whether the change was applied.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Status was read, a change was applied, or a disruptive change was previewed. |
| 1 | The target rejected the change. |
| 2 | Arguments were missing or invalid, including a level outside 0 through 100. |
| 3 | The machine name was not found. |
| 4 | The machine could not be reached or did not expose the requested control. |
