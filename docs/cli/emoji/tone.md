# `ed emoji tone`

Sets the default skin tone Edith applies to the emoji that support one.

Usage:

```
ed emoji tone <tone> [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<tone>` | `default`, `light`, `medium-light`, `medium`, `medium-dark`, `dark` | required | Chooses the tone written to `emojiSkinTone`. |
| `--json` | flag | off | Emits one JSON document on stdout. |

The six tokens are the six values of the setting, in order:

| Token | `emojiSkinTone` | Sample |
| --- | --- | --- |
| `default` | 0 | ✋ |
| `light` | 1 | ✋🏻 |
| `medium-light` | 2 | ✋🏼 |
| `medium` | 3 | ✋🏽 |
| `medium-dark` | 4 | ✋🏾 |
| `dark` | 5 | ✋🏿 |

The token is trimmed and lowercased before it is matched, so `Dark` and ` dark `
are accepted. It is matched exactly after that, so `medium dark` with a space is
not `medium-dark` and exits 3 with the list of six.

The plain response repeats the token and the sample hand:

```
$ ed emoji tone medium
skin tone set to medium ✋🏽
```

The JSON response has two stable fields:

```json
{
  "sample": "✋🏽",
  "tone": "medium"
}
```

`tone` is the canonical token, so it is `medium-light` even if you typed
`MEDIUM-LIGHT`, and `sample` is the raised hand at that tone, which is the same
sample the settings pane shows.

Examples:

```
ed emoji tone dark
ed emoji tone default
ed emoji tone medium-light --json
```

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | The tone was written. |
| 2 | The command line was invalid, including no argument at all. |
| 3 | The argument is not one of the six tokens. |

There is no 4 here. `tone` checks neither the Emoji Picker extension nor the
running app, because all it does is write an integer to the
`com.pulkit.edith.shared` defaults suite and post the same `settingsChanged`
notification `ed config set` sends. A running picker adopts the new tone on that
notification and repaints; a closed Edith picks it up when it next starts.

The command is `ed config set emojiSkinTone <0-5>` with names instead of
numbers, and the two are interchangeable. The setting's own range check is what
rejects `ed config set emojiSkinTone 9`, and this command's token list is what
rejects `ed emoji tone tan`.

The tone applies to the roughly 330 emoji that have toned variants, and only
when Edith produces the character: [`ed emoji insert`](./insert.md) and the
picker both apply it, while [`ed emoji ls`](./ls.md) always prints base
characters and lists the variants separately. An emoji with no tone support is
never affected, so a dark default leaves 🚀 exactly as it is. An emoji whose
variants do not all render on this Mac is treated as having none, and also stays
at its base character.

## Where to go next

- [`ed emoji insert`](./insert.md), which applies this tone
- [`ed emoji`](./README.md), the rest of this group
- [`ed config`](../config/README.md), for `emojiSkinTone` and the rest of the `emoji` group
- [All `ed` commands](../README.md)
