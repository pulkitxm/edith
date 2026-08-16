# `ed machines files duplicate`

Copies a file beside itself, naming the copy the way the window names it.

```
ed machines files duplicate <machine> <path> [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `machine` | machine name, SSH alias, id or unambiguous prefix | required | Which machine. |
| `path` | remote path | required | What to duplicate. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "machine": "Asus TUF 7",
  "path": "/home/pulkit/report.txt",
  "to": "/home/pulkit/report copy.txt"
}
```

```
ed machines files duplicate tuf /home/pulkit/report.txt
ed machines files duplicate tuf /srv/app/config
ed machines files duplicate tuf /home/pulkit/report.txt --json
```

The name is worked out on the machine: the extension is kept, ` copy` is added
to the stem, and if that is taken the number climbs, so `report.txt` gives
`report copy.txt`, then `report copy 2.txt`, then `report copy 3.txt`.
Duplicating twice never overwrites the first copy. The copy itself is `cp -R`,
so a directory duplicates whole, and the cap is 300 seconds.

One case differs from the app. A name that is nothing but an extension, such as
`.bashrc`, has an empty stem on the machine's arithmetic, so the CLI produces
` copy.bashrc` with a leading space where the window produces `.bashrc copy`.

A failure exits 1 and hands back what the machine printed:

```
$ ed machines files duplicate tuf /etc/hosts
error: could not duplicate /etc/hosts on Asus TUF 7
hint: cp: cannot create regular file '/etc/hosts copy': Permission denied
```

## Where to go next

- [`ed machines files`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
