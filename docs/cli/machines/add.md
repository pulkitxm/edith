# `ed machines add`

Adds a machine to Edith's list. It appears in the app straight away.

```
ed machines add <name> --host <host> [--port <n>] [--user <u>] [--key <path>]
                       [--alias <sshAlias>] [--mac <address>]
                       [--password-stdin | --key-passphrase-stdin] [--json]
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<name>` | string, required | none | What to call it. Must not match an existing machine's name, case-insensitively. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--host` | string, **required** | none | Hostname or address to reach it at. Omitting it exits 2. |
| `--port` | integer, 1 to 65535 | `22` | SSH port. |
| `--user` | string | `""` | Username to log in as. Left empty, the ssh target is the bare host. |
| `--key` | path | none | Private key to authenticate with, instead of the SSH agent. `~` is expanded, and the file must exist. |
| `--alias` | string | none | Record this as an entry from your `ssh config` with this alias, which is what the app's picker writes when you choose a host from there. |
| `--mac` | string | none | MAC address for `ed machines power wake` to send its packet to. |
| `--password-stdin` | flag | off | Read one line of login password from stdin and store it in the keychain. Sets `auth` to `Password`. |
| `--key-passphrase-stdin` | flag | off | Read the key file's passphrase from stdin instead of a password. Only meaningful with `--key`. |
| `--json` | flag | off | Emit JSON on stdout instead of the confirmation block. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

Auth is resolved in one order and the first match wins: `--password-stdin` gives
`Password`, then `--key` gives `Key file`, and everything else gives
`SSH agent`. Passing both `--password-stdin` and `--key` therefore stores the
password and ignores the key.

```
$ ed machines add box --host 10.0.0.4 --user pi
added box
  target   pi@10.0.0.4
  auth     SSH agent
```

## `--json` shape

The new machine's record, exactly as `ed machines ls` reports it.

## Examples

```
ed machines add box --host 10.0.0.4 --user pi
ed machines add box --host 10.0.0.4 --user pi --key ~/.ssh/id_ed25519
ed machines add shed --host 10.0.0.9 --mac be:f0:86:8d:58:12 --json
printf '%s' "$PASS" | ed machines add box --host 10.0.0.4 --user pi --password-stdin
printf '%s' "$PHRASE" | ed machines add box --host 10.0.0.4 --key ~/.ssh/id_ed25519 --key-passphrase-stdin
```

## Behaviour notes

Writes one entry to `machines.json`, writes the secret to the keychain when one
was piped, and posts `machinesChanged`. It never dials the machine, so adding a
host that is switched off succeeds.

Secrets are only ever read from stdin, so they cannot land in a process listing
or your shell history. `ed` takes the first line, stripped of its newline; an
empty line is a failure rather than an empty password:

```
$ printf '' | ed machines add box --host 10.0.0.4 --password-stdin
error: no password arrived on stdin
hint: pipe it, for example: printf '%s' "$PASS" | ed machines add ...
```

Everything is checked before anything is written, so a rejected `add` leaves the
directory untouched. The refusals, with their codes:

```
$ ed machines add "Asus TUF 7" --host 10.0.0.4
error: a machine called Asus TUF 7 already exists
hint: pick another name, or edit the existing one with `ed machines edit Asus TUF 7`

$ ed machines add box --host 10.0.0.4 --port 70000
error: --port must be between 1 and 65535

$ ed machines add box --host 10.0.0.4 --key /tmp/no-such-key
error: there is no key file at /tmp/no-such-key
hint: point --key at a private key, or pass --agent to use the SSH agent

$ ed machines add box --host 10.0.0.4 --password-stdin --key-passphrase-stdin
error: a machine has either a password or a key passphrase, not both

$ ed machines add box --host 10.0.0.4 --key-passphrase-stdin
error: --key-passphrase-stdin only means something with --key
```

The missing key file exits 3, because it is a thing you named that does not
exist. The other four exit 1. A missing `--host` exits 2, from the parser.

`--alias` changes how the machine is dialled, not just how it is labelled. An
`ssh config` machine is handed to `ssh` as the bare alias, so `--port`, `--user`
and `--key` are recorded on the record but never reach the command line;
whatever your `~/.ssh/config` says for that host is what applies.

## Where to go next

- [`ed machines`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
