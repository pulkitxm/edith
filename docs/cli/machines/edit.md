# `ed machines edit`

Changes a machine already on the list. `--name` renames it; every other option
replaces one field and everything you leave out is untouched.

```
ed machines edit <machine> [--name <n>] [--host <h>] [--port <n>] [--user <u>]
                           [--key <path>] [--agent] [--mac <address>]
                           [--password-stdin | --key-passphrase-stdin]
                           [--sudo-password-stdin | --forget-sudo-password] [--json]
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | string, required | none | Machine name, ssh alias, id or unambiguous prefix. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--name` | string | unchanged | Rename it. Refused if another machine already holds that name. |
| `--host` | string | unchanged | Hostname or address to reach it at. |
| `--port` | integer, 1 to 65535 | unchanged | SSH port. |
| `--user` | string | unchanged | Username to log in as. An empty value is accepted and means "no user". |
| `--key` | path | unchanged | Private key to authenticate with. Sets `auth` to `Key file`. |
| `--agent` | flag | off | Authenticate with the SSH agent instead of a key file. Cannot be combined with `--key`. |
| `--mac` | string | unchanged | MAC address for wake-on-LAN. Pass an empty value, `--mac ""`, to clear it. |
| `--password-stdin` | flag | off | Read a new login password from stdin, store it in the keychain, and set `auth` to `Password`. |
| `--key-passphrase-stdin` | flag | off | Read the key file's passphrase from stdin and store it. |
| `--sudo-password-stdin` | flag | off | Read this account's sudo password from stdin and store it in the keychain. It is what `power reboot`, `power shutdown` and the unit verbs use to become root. Cannot be combined with `--forget-sudo-password`. |
| `--forget-sudo-password` | flag | off | Delete the stored sudo password. Privileged verbs go back to trying `sudo -n`. |
| `--json` | flag | off | Emit JSON on stdout instead of the confirmation block. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

## `--json` shape

The updated machine's record. Neither sudo flag appears in it: a stored secret
lives in the keychain, never in `machines.json`.

## Examples

```
ed machines edit box --name shed
ed machines edit shed --host 10.0.0.9 --port 2222
ed machines edit shed --key ~/.ssh/id_ed25519
ed machines edit shed --agent
ed machines edit shed --mac ""
printf '%s' "$PHRASE" | ed machines edit shed --key ~/.ssh/id_ed25519 --key-passphrase-stdin
printf '%s' "$SUDO" | ed machines edit shed --sudo-password-stdin
ed machines edit shed --forget-sudo-password
```

## Behaviour notes

Rewrites the entry in `machines.json`, writes the keychain item when a secret
was piped, and posts `machinesChanged`. Like `add`, everything is validated
before the write, so a refused edit changes nothing.

`--password-stdin` is applied last and wins outright: passing it alongside
`--key` stores the password and sets `auth` to `Password`. The key path lives
inside `auth` and nowhere else, so it is dropped rather than kept; pass `--key`
again when you want the key file back.

Two shapes surprise people:

- `--key-passphrase-stdin` on its own, with no `--key` and no `--agent`, is not
  refused here the way it is in `add`. The passphrase is written to the keychain
  and `auth` is left exactly as it was, so a machine on the SSH agent gains a
  stored passphrase that nothing reads. Pass `--key` in the same command when
  you mean to switch to a key file.
- `ed machines edit <machine>` with no options at all is legal. It rewrites the
  record with the values it already had and posts `machinesChanged`, so it is a
  no-op with a notification.

```
$ ed machines edit studio --agent --key ~/.ssh/id_ed25519
error: --agent and --key are different answers to the same question
```

That exits 1, as do a duplicate `--name` and an out-of-range `--port`. A `--key`
pointing at nothing exits 3. An unknown machine exits 3, but note the ordering:
stdin is read before the machine is resolved, so a piped secret is consumed even
when the name turns out to be wrong.

## Where to go next

- [`ed machines`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
