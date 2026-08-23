# `ed apps quit`

Plans or applies a request to quit one running app, or every unprotected app.
Finder, Edith, and Edith's menu bar helper are always protected.

```
ed apps quit <app> [--force] [--yes] [--json]
ed apps quit --all [--force] [--yes] [--json]
```

Without `--yes`, both forms are previews. They resolve the exact targets, print
the plan, change nothing, and do not require Edith to be running.

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<app>` | running app name or bundle id | none | Select an exact name, exact bundle id, or unambiguous name prefix. Required unless `--all` is used. Running names and bundle ids complete dynamically. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--all` | flag | off | Select every app except Finder and both Edith processes. Cannot be combined with an app name. |
| `--force` | flag | off | Plan or request `forceTerminate` instead of a normal quit. This can prevent an app from saving. |
| `--yes` | flag | off | Apply the exact plan. Required for named targets and `--all`. |
| `--json` | flag | off | Emit one JSON document on stdout. |
| `--help`, `-h` | flag | off | Print help and exit 0. |
| `--version` | flag | off | Print the CLI version and exit 0. |

Naming neither a target nor `--all` exits 1. Combining both also exits 1:

```
$ ed apps quit
error: say which app to quit
hint: pass a name, or --all

$ ed apps quit --all Safari
error: --all quits everything, so it takes no app name
```

Resolution tries a case-insensitive exact name, a case-insensitive exact bundle
id, then an unambiguous name prefix. Missing and ambiguous targets exit 3.
Protected named targets exit 1 before any request is sent.

## Preview and apply

A named preview is one line on stdout:

```
$ ed apps quit Spotify
would quit Spotify; pass --yes to apply
```

An all-app preview includes the exact names captured by the plan:

```
$ ed apps quit --all
would quit 3 apps: Music, Safari, Spotify; pass --yes to apply
```

Previews work while Edith is closed. Applying needs the menu bar helper because
the Automation grant belongs to Edith rather than the `ed` process:

```
$ ed apps quit Spotify --yes
asked Edith to quit Spotify
```

If the helper is closed, only the confirmed form exits 4:

```
error: quitting apps needs the Edith menu bar app to be running
hint: start Edith, then retry
```

## `--json` shape

Preview and apply use the same stable object. `applied` says whether the request
was sent. `changed` is the number of exact targets handed to Edith, not proof
that every app has already closed. `targets` contains the same rows as
`ed apps ls`.

```json
{
  "applied": false,
  "changed": 0,
  "force": false,
  "operation": "apps.quit",
  "targets": [
    {
      "active": false,
      "bundleID": "com.spotify.client",
      "name": "Spotify",
      "pid": 18719
    }
  ]
}
```

With `--yes`, the same plan becomes:

```json
{
  "applied": true,
  "changed": 1,
  "force": false,
  "operation": "apps.quit",
  "targets": [
    {
      "active": false,
      "bundleID": "com.spotify.client",
      "name": "Spotify",
      "pid": 18719
    }
  ]
}
```

## Behaviour notes

The CLI and System page use the same EdithKit operation center for discovery,
resolution, protected-app filtering, exact target planning, and execution. The
System page's confirmation dialogs supply the confirmation that `--yes`
supplies on the command line.

Confirmed CLI execution sends one `com.pulkit.edith.requestQuitApps`
notification with the exact planned PIDs and the force mode. The helper does not
recompute an `--all` selection, so an app launched after the preview cannot be
quit accidentally. It validates protected bundle ids again before calling
`terminate()` or `forceTerminate()`.

The request is fire and forget. An app with unsaved changes may show a save
dialog and remain open after `ed` exits 0. Check the list again when a script
needs to know whether the target closed:

```
ed apps quit Spotify --yes
sleep 2
ed apps ls --json | jq -r '.[].name'
```

`--force` skips normal termination and can lose unsaved work. It still requires
`--yes`.

## Examples

```
ed apps quit Spotify
ed apps quit Spotify --yes
ed apps quit com.spotify.client --force --yes
ed apps quit --all --json
ed apps quit --all --yes --json
```

## Where to go next

- [`ed apps`](./README.md), the rest of this group
- [`ed apps ls`](./ls.md), discovery and output fields
- [All `ed` commands](../README.md)
