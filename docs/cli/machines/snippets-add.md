# `ed machines snippets add`

Saves a command against a machine, or against every machine.

```
ed machines snippets add [--shared] [--json] <machine> <title> <command...>
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | string, required | none | Machine name, ssh alias, id or unambiguous prefix. Still required with `--shared`, and still has to resolve. |
| `<title>` | string, required | none | What to call it. |
| `<command...>` | one or more words, required | none | The command to save, captured verbatim and joined with single spaces. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--shared` | flag | off | Offer it on every machine rather than just this one, which is what leaving the machine unset does in the UI. |
| `--json` | flag | off | Emit JSON on stdout instead of the line. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

```
$ ed machines snippets add studio logs log show --last 5m
saved logs on Studio Mac
```

## `--json` shape

```json
{
  "command": "log show --last 5m",
  "id": "F8D5CE93-C9B4-4A05-9109-9AEB1BD806BA",
  "index": 0,
  "sharedAcrossMachines": false,
  "title": "logs"
}
```

As with `forwards add`, `index` is `0` rather than the new row's position. List
the snippets afterwards if you need the number.

## Examples

```
ed machines snippets add studio logs log show --last 5m
ed machines snippets add studio disk df -h
ed machines snippets add --shared studio uptime uptime
```

## Behaviour notes

Appends to `snippets.json` and posts `machinesChanged`. Everything after the
title is the command, verbatim, so `--shared` and `--json` have to come before
the machine name; written after the title they are saved as part of the command
instead of read as flags.

The words are joined with single spaces, so the saved string is not
byte-identical to what you typed when you used several spaces or quoted an
argument containing them. A command that is empty or only whitespace exits 1
with `a snippet needs a command to run`.

A shared snippet has no machine of its own, so it survives
`ed machines rm` and shows up on every machine's list.

## Where to go next

- [`ed machines`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
