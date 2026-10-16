# `ed attention rules import`

Validates a JSON rule document and merges categories and rules by stable ID.
Existing entries omitted from the document remain unchanged. All validation
finishes before anything is saved. Run the same import again to update the same
rules without creating duplicates.

```
ed attention rules import rules.json --dry-run --json
ed attention rules import rules.json --json
```

The document must contain `categories` and `rules` arrays. Use an empty categories
array to import rules targeting existing categories. Rule IDs must be unique,
category IDs must be unique, names cannot be empty, categories must exist and
rules must have match criteria. The JSON response reports input counts and
whether the changes were saved.

## Where to go next

- [`ed attention rules`](./README.md)
- [`ed attention rules export`](./export.md)

- [`ed attention`](../README.md)
