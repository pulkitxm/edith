# `ed schema`

Prints the JSON Schema for the whole configuration document.

```
ed schema
```

It declares no options of its own. `--help` and `--version` come from the
argument parser. There is no `--json` flag because the output is already a JSON
document, always pretty printed with two-space indentation and sorted object
keys.

Shape, with one property per writable setting. The current catalogue has 213
settings: 190 properties appear here and the 23 read-only settings are omitted.
Three real properties are shown:

```json
{
  "$id": "https://edith.pulkit.page/schema/config.json",
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "additionalProperties": false,
  "description": "Every setting the Edith UI exposes, as accepted by `ed config import`. Keys map one to one onto the preferences the app reads at runtime.",
  "properties": {
    "clipboardIgnoredApps": {
      "description": "Comma separated bundle identifiers never captured.",
      "type": "string",
      "x-format": "comma-separated",
      "x-group": "clipboard",
      "x-scope": "shared"
    },
    "limitsProvider": {
      "default": "claude",
      "description": "Provider shown first in the limits UI.",
      "enum": [
        "claude",
        "codex"
      ],
      "type": "string",
      "x-group": "limits",
      "x-scope": "shared"
    },
    "musicFavourites": {
      "description": "Relative paths of favourited tracks.",
      "items": {
        "type": "string"
      },
      "type": "array",
      "x-group": "music",
      "x-scope": "shared"
    }
  },
  "title": "Edith configuration",
  "type": "object"
}
```

Every property carries `description`, `x-group` and `x-scope`, where the scope
is `shared` for the suite both surfaces read and `standard` for the app's own
defaults. `type` is `boolean`, `integer`, `number`, `string`, `array` or
`object`. A comma-separated setting is typed as `string` and marked
`x-format: comma-separated`; a list setting is typed as `array` with
`items: {"type": "string"}`. `enum` appears only when the setting has an allowed
set, and `default` only when it has a fallback, so a setting with no fallback
simply has no `default` key rather than a null one.

Read-only settings are left out of the document entirely, and there are more of
them than the `perm*Granted` mirror of macOS permission state and the
`last*BackupAt` timestamps: everything the app records about itself is read-only
too, `micMuted`, `musicLastTrack`, `presenterAutoActive` and `notifSessionLevel`
among them. `ed config import` would refuse all of it anyway.

Examples

```
ed schema > edith-config.schema.json
ed schema | jq '.properties.limitsProvider'
ed schema | jq -r '.properties | keys[]'
```

## Where to go next

- [Getting started with `ed`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
