# `ed config import`

Applies a JSON document of settings, reporting what it did rather than failing
on the parts it cannot use.

```
ed config import <file|-> [--dry-run] [--json]
```

| Argument | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `file` | a path, `~` expanded, or `-` for stdin | required | The document to apply |

| Option | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--dry-run` | flag | `false` | Report what would change without writing |
| `--json` | flag | `false` | Emit JSON on stdout |

Keys are processed in sorted order and each one lands in exactly one of three
buckets. `applied` is a value that parsed and differs from what is stored;
`unchanged` is a value that parsed and matches; `skipped` is everything else,
which is an unknown key, a read-only key, a `map` setting, a value of the wrong
JSON type, or a string outside the setting's allowed list.

What each type wants in the document:

| Type | Wants | Note |
| --- | --- | --- |
| `bool` | a JSON boolean | a JSON `1` or `0` is accepted too |
| `int` | a JSON number | a decimal is truncated, so `60.7` becomes `60` |
| `number` | a JSON number | |
| `string`, `csv` | a JSON string | checked against the allowed list; a `csv` value is one comma separated string, not an array |
| `stringList` | a JSON array of strings | a bare string is skipped |
| `map` | nothing | always skipped |

```json
{
  "applied": [
    "appearance"
  ],
  "dryRun": true,
  "skipped": [
    "cleanerCategoryDefaults",
    "limitsProvider",
    "micMuted",
    "notARealKey",
    "showDockIcon"
  ],
  "unchanged": [
    "warnPercent"
  ]
}
```

```
ed config import edith.json
ed config import edith.json --dry-run
ed config export | ed config import - --dry-run
cat edith.json | ed config import -
```

The count goes to stdout and the commentary goes to stderr, so a pipeline sees
only the number:

```
$ ed config import edith.json --dry-run
would apply 1 setting
1 already matched
skipped: cleanerCategoryDefaults, limitsProvider, micMuted, notARealKey, showDockIcon
```

A document where nothing is usable still exits 0: skipping is a report, not a
failure. `settingsChanged` is posted once at the end, and only when this was not
a dry run and at least one setting actually changed. A path that cannot be read
exits 3, and a document that is not a JSON object exits 1.

Since a setting whose value already matches counts as unchanged rather than
applied, re-importing a document you just exported reports that there is nothing
to do:

```
$ ed config export > edith.json
$ ed config import edith.json --dry-run
would apply 0 settings
83 already matched
```

## Where to go next

- [`ed config`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
