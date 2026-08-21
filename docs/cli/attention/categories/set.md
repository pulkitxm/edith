# `ed attention categories set`

Assigns one summary entity to a category. Rules are applied at query time, so the
change reclassifies existing history without rewriting events.

```
ed attention categories set <entity> <category> [--name <display-name>] [--json]
```

Use an entity ID from `ed attention summary --json`. Accepted forms are
`identity:<rule-id>`, `app:<bundle-id>`, and `web:<domain>`. The category can be
its ID or exact display name. `--name` sets the unified friendly name.

## Where to go next

- [`ed attention`](../README.md)
- [`ed attention summary`](../summary.md)
