# `ed apps quit`

Asks Edith to quit an app. Names one app, or passes `--all` to quit everything
except Finder and Edith.

```
ed apps quit <app> [--force] [--json]
ed apps quit --all [--yes] [--force] [--json]
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<app>` | string, optional | none | App name, bundle id, or an unambiguous prefix of a name. Required unless `--all` is given, and refused when it is. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--all` | flag | off | Quit everything except Finder, Edith and Edith's menu bar helper. Cannot be combined with an app name. |
| `--force` | flag | off | Use `forceTerminate` instead of `terminate`, which kills the app outright rather than letting it save first. Applies to both forms. |
| `--yes` | flag | off | Actually quit. Required with `--all`; without it the command counts the targets and touches nothing. Accepted and ignored for a single app. |
| `--json` | flag | off | Emit JSON on stdout instead of the human line. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |
| `--version` | flag | off | Print the CLI version on stdout and exit 0. |

The checks run in a fixed order, and the order is worth knowing because it
decides which failure you see first.

Naming nothing at all is a failure rather than a no-op, and so is naming both:

```
$ ed apps quit
error: say which app to quit
hint: pass a name, or --all

$ ed apps quit --all Safari
error: --all quits everything, so it takes no app name
```

Both of those exit 1, not 2. They are checked inside the command rather than by
the argument parser, which only sees a valid command line in each case: an
optional positional that is absent, and an optional positional that is present.

Next comes the app check, before anything is resolved or counted. With Edith
closed every form of this command exits 4 with the same message, including the
`--all` dry run that would not have quit anything:

```
error: quitting apps needs the Edith menu bar app to be running
hint: start Edith, then retry
```

Only then is the app name resolved, or the `--all` list counted.

Resolution tries three things in order and stops at the first that works: an
exact match on the localized name, an exact match on the bundle id, then a
unique prefix of a name. All three are case-insensitive, and only the last is a
prefix match, so a partial bundle id matches nothing. A prefix that matches
several apps fails with the list rather than guessing, and a name that matches
none says how to find the right one:

```
$ ed apps quit nosuchapp
error: no running app called nosuchapp
hint: run `ed apps ls` to see them
```

Both of those exit 3. Only apps `ed apps ls` shows are candidates, so a menu bar
only app cannot be named here at all.

`--all` counts its targets and, without `--yes`, reports the count and stops:

```
$ ed apps quit --all
would quit 6 app(s)
nothing was quit; pass --yes to go ahead
```

The count is the listed apps minus Finder, minus Edith, minus Edith's menu bar
helper, which is not in the list to begin with. The first line is stdout and
the second is stderr, so `ed apps quit --all | wc -l` sees one line. With
`--yes` the request goes out, and the wording changes to the past tense of
asking rather than of quitting:

```
$ ed apps quit --all --yes
asked Edith to quit 6 app(s)
```

A single app reads the same way:

```
$ ed apps quit Spotify
asked Edith to quit Spotify
```

## `--json` shape

Three shapes, one per form. `--all` without `--yes` reports what it counted and
that it did nothing:

```json
{
  "apps": 6,
  "quit": false
}
```

`--all --yes` is the same object with `quit` flipped:

```json
{
  "apps": 6,
  "quit": true
}
```

Quitting one app emits that app's row, the same four keys `ed apps ls` uses,
describing the app as it was at the moment the request was sent:

```json
{
  "active": false,
  "bundleID": "com.spotify.client",
  "name": "Spotify",
  "pid": 18719
}
```

`apps` is the count of targets, not of apps that quit, and `quit` says whether
the request was sent rather than whether anything closed. Neither form waits for
an answer, so neither can tell you more than that. With `--json` the stderr note
about `--yes` is not printed: the document is the whole output.

## Examples

```
ed apps quit Spotify
ed apps quit com.spotify.client --force
ed apps quit --all
ed apps quit --all --yes --json
```

## Behaviour notes

This mutates nothing that `ed` owns. It writes no file and changes no setting.
What it does is post one `com.pulkit.edith.requestQuitApps` distributed
notification carrying either `all` and `force`, or `pid` and `force`, and then
return. The menu bar helper observes that name and calls `terminate()` or
`forceTerminate()` on the matching applications.

It is fire and forget. `ed` does not wait for a reply, does not learn whether
the app closed, and exits 0 as soon as the notification is posted. An app with
unsaved changes puts up a save dialog and stays open; `ed` has already exited 0
by then. If you need to know, list again and look:

```
ed apps quit Spotify
sleep 2
ed apps ls --json | jq -r '.[].name'
```

The helper refuses to quit `com.apple.finder`, `com.pulkit.edith` and
`com.pulkit.edith.statusbar` whatever it is asked, and it recomputes the `--all`
list itself at the moment it acts rather than trusting the count `ed` sent. That
guard is the last word, not the first: `ed apps quit Finder` resolves cleanly,
posts the request, prints `asked Edith to quit Finder` and exits 0, and then
nothing happens. The same is true of `ed apps quit Edith`. Success here means
the request was sent, and a protected app is the one case where a sent request
is guaranteed to be dropped.

`--force` maps to `forceTerminate`, which is the hard kill: no save prompt, no
chance to flush anything to disk. `--yes` is only consulted on the `--all` path,
so `ed apps quit Spotify --yes` is accepted and the flag does nothing.

## Where to go next

- [`ed apps`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
