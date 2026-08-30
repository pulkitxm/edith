# `ed emoji insert`

Types one emoji into whatever app is frontmost, the same way clicking a cell in
the picker does, and records the use in the frequency ledger.

Usage:

```
ed emoji insert <emoji> [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<emoji>` | the character itself, a Unicode hexcode, or part of a name | required | Names the emoji to type. |
| `--json` | flag | off | Emits one JSON document on stdout. |

The argument is resolved in three steps, and the first one that hits wins:

1. **An exact character.** Both base characters and toned variants are matched,
   so `ed emoji insert 👍` and `ed emoji insert 👍🏽` both find thumbs up.
2. **A hexcode.** One or more code points in hexadecimal, joined by hyphens or
   spaces, in either case: `1F600`, `1f1ee-1f1f3`, `1F636-200D-1F32B-FE0F`.
3. **Part of a name.** The string goes through the same normalisation and the
   same ranked search as [`ed emoji ls --search`](./ls.md), and the top result is
   used.

That means `ed emoji insert fire` types 🔥 rather than asking which fire you
meant, and `ed emoji insert ':thumbs_up:'` types thumbs up. Quote anything with a
space in it, because the argument is a single positional.

Your default skin tone is applied to everything except a toned variant you asked
for by hand. A base character, a hexcode and a name all end up as
`character(tone:)` against `emojiSkinTone`, so with the tone set to medium
`ed emoji insert 👍` types 👍🏽. Passing 👍🏻 types 👍🏻 whatever the setting says. An
emoji with no tone support ignores the setting entirely, so 🚀 is always 🚀.

The plain response names the character that was actually typed, which is how you
see the tone that was applied:

```
$ ed emoji insert 👍
inserted 👍🏽
```

The JSON response has two stable fields:

```json
{
  "emoji": "👍🏽",
  "operation": "emoji.insert"
}
```

Examples:

```
ed emoji insert 🚀
ed emoji insert 1F600
ed emoji insert rocket
ed emoji insert 'thumbs up' --json
```

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | The character was resolved, the helper posted its key events, and the use was recorded. |
| 2 | The command line was invalid, including no argument at all. |
| 3 | Nothing in the catalog matches the argument. |
| 4 | The Emoji Picker extension is off, Edith's menu bar app is not running or answering, or Accessibility prevented insertion. |

The checks happen in that order: extension, then resolution, then the app. So a
nonsense argument is a 3 even with Edith closed, and a good argument with Edith
closed is a 4 that records nothing:

```
$ ed emoji insert xyzzy
error: no emoji matches xyzzy
hint: run `ed emoji ls` to see what this Mac can render
```

Behaviour: the command hands the character to the running app and waits for the
matching acknowledgement. The app posts a key down and a key up carrying the
Unicode string to the session event tap about fifty milliseconds later, records
the use once, and then answers. The emoji therefore lands in the app that has
focus at that moment, not necessarily the one that had focus when you pressed
Return. Nothing is put on the pasteboard. Because Edith types rather than
presses a key, Accessibility access is what makes this work. If the grant is
missing, macOS is asked to show its prompt, no use is recorded, and the command
exits 4. An app with secure keyboard entry on, such as a password field, can
still ignore an event after macOS accepted it.

## Where to go next

- [`ed emoji ls`](./ls.md), to find the name or the character first
- [`ed emoji tone`](./tone.md), for the tone this command applies
- [`ed emoji`](./README.md), the rest of this group
- [`ed permissions`](../permissions/README.md), for Accessibility access
- [All `ed` commands](../README.md)
