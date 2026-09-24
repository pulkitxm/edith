# `ed jev`

Jev is TypeSafe's System One model. It reads a state and answers named
questions with a yes/no probability, a choice over up to 255 options with a full
distribution, or a score on an ordered rubric, usually in well under a second.
It never writes text.

Edith calls Jev only while a TypeSafe API key is saved, either in Settings > Jev
or with `ed jev key set`. Without a key every Jev feature is off and each
feature keeps its own rules. The key lives in the background agent's Keychain
item, and every request goes through the agent, so the app, the menu bar helper
and `ed` share one cache and one rate limit.

## At a glance

| Command | What it does |
| --- | --- |
| `ed jev` | Runs `status`, which is the default subcommand |
| `ed jev status` | Whether a key is set, and with `--probe` whether it can decide |
| `ed jev key show` | Whether a key is saved, and how it ends |
| `ed jev key set` | Store the key read from stdin |
| `ed jev key clear` | Remove the key, which turns every Jev feature off |
| `ed jev ask` | Send a raw state and typed questions |

## Commands

- [`ed jev status`](./status.md)
- [`ed jev key show`, `ed jev key set` and `ed jev key clear`](./key.md)
- [`ed jev ask`](./ask.md)

Every command needs the background agent and exits 4 when it is not running,
when no key is set, or when the TypeSafe organization has no credits.

- [`ed mcp`](../mcp/README.md), which lists `edith_find` while a key is set
- [All command groups](../README.md)
