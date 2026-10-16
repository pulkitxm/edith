# `ed machines terminal`

`ed machines terminal` acts on terminal tabs that are already open in the Edith
main app. It is separate from remote SSH execution: the command goes through the
running app and is written into its existing terminal processes.

## Commands

- [`ed machines terminal broadcast`](./broadcast.md)

The group has no default subcommand. `ed machines terminal` prints its help and
exits 0.

## App and machine identity

The machine argument accepts `local`, `this-mac`, `thismac` and `mac` for This
Mac, including when no remote machines are configured. Remote targets accept
the same exact name, SSH alias, UUID or unambiguous prefix as other machine
commands. `ed` resolves the target to the stable machine UUID before contacting
the app. The app uses that UUID to select terminal tab sets, so renaming a
machine cannot send the line to a different machine.

Requests and replies carry a unique request id. A concurrent app operation
cannot be mistaken for this command's result.

This group exits 4 when the Edith main app is not running or does not answer in
time. It exits 3 when the machine is unknown, has no open terminal tabs or has
no running terminal tabs. A partial delivery exits 1 and reports exact sent and
unavailable counts.

## Where to go next

- [`ed machines`](../machines/README.md) for machine setup and SSH commands
- [`ed machines broadcast`](../machines-power/README.md) for fleet-wide SSH execution
- [All `ed` commands](../README.md)
