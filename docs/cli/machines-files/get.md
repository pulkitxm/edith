# `ed machines files get`

Downloads one file from the machine to this Mac.

```
ed machines files get <machine> <remote> [local] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `machine` | machine name, SSH alias, id or unambiguous prefix | required | Which machine to read from. |
| `remote` | remote file path | required | The file to download. |
| `local` | local path, `~` expanded | the remote file's name, in the working directory | Where to write it. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "local": "/Users/pulkit/os-release",
  "remote": "/etc/os-release",
  "sizeBytes": 382
}
```

```
ed machines files get tuf /etc/os-release
ed machines files get tuf /var/log/syslog ~/Desktop/syslog.txt
ed machines files get tuf /etc/hosts --json
```

The transfer is `cat <remote>` on the far side, streamed 128 KB at a time into a
staging file beside the destination over the shared connection. There is no
timeout: a large file takes as long as it takes. A completed staging file replaces
the destination, so a shorter second download has no trailing bytes. A failure
removes only the staging file and preserves any file that was already there. The
contents are never accumulated in memory, and only one staged copy is kept.

Before the first byte moves, `ed` asks the machine how big the file is with
`stat`, capped at 30 seconds, and then keeps one line on stderr up to date as
the bytes land: the file name, what has arrived, the total, and a percentage.
That line is repainted on a timer roughly ten times a second rather than once
per chunk, and it is transient, cleared when the transfer ends or fails:

```
$ ed machines files get tuf /srv/backup.tar.gz
  ⠹ backup.tar.gz  24.0 MB of 87.3 MB  27% 14s
```

It is written only when stderr is a terminal, and never with `--json`, so a
piped or redirected run is as quiet as it ever was. When the `stat` cannot
answer, the meter falls back to the bytes received alone, with no total and no
percentage.

`sizeBytes` is measured from the local file after the transfer rather than from
the size the machine reported for the meter, so it is what actually landed, and
it is 0 if the file cannot be stat'ed. The human line is the path and that size:

```
$ ed machines files get tuf /etc/os-release
/Users/pulkit/os-release  382 B
```

A remote path that does not exist, or one `cat` refuses such as a directory,
exits 1, and the half-written staging file is removed rather than left looking
complete:

```
$ ed machines files get tuf /etc/shadow
error: download failed: cat: /etc/shadow: Permission denied
```

## Where to go next

- [`ed machines files`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
